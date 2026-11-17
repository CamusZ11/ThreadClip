import AppKit
import Combine
import Foundation
import ThreadHangerCore

private actor CodexScanner {
    struct Snapshot {
        let observations: Result<[ThreadObservation], Error>
        let recentCandidates: [HangerCard]?
        let diagnostic: String
    }

    private let source = CodexSource()
    private let navigation = CodexNavigationLog()

    func read(
        _ tracked: [String: String], desktopStartedAt: Date, waiting: [String: String], recentCount: Int
    ) -> Snapshot {
        let result = Result {
            try source.scan(
                trackedThreadIDs: Set(tracked.keys), trackedTurnIDsByThread: tracked,
                desktopStartedAt: desktopStartedAt, trackedWaitingRequests: waiting
            )
        }
        let recent = (try? result.get()).flatMap { observations -> [HangerCard]? in
            guard recentCount > 0 else { return [] }
            let newActiveCount = observations.filter {
                ($0.status == .running || $0.status == .waiting) && tracked[$0.threadID] == nil
            }.count
            // Leave room for current or unread threads that are skipped when the lists are combined.
            return try? source.recentCards(limit: recentCount + tracked.count + newActiveCount)
        }
        return Snapshot(observations: result, recentCandidates: recent, diagnostic: source.diagnostic)
    }

    func confirmsOpening(
        threadID: String, hostID: String?, processID: Int32, processStartedAt: Date, requestedAt: Date
    ) -> Bool {
        let isLocal = source.containsLocalThread(threadID)
        guard (hostID == nil) == isLocal else { return false }
        return navigation.confirmsRoute(
            threadID: threadID, hostID: hostID, processID: processID, processStartedAt: processStartedAt,
            requestedAt: requestedAt, now: Date(), allowExistingRoute: true
        )
    }

}

@MainActor
final class HangerRuntime: ObservableObject {
    enum LinkResult {
        case accepted(NSRunningApplication)
        case noHandler
        case failed
    }

    typealias LinkCompletion = @MainActor (LinkResult) -> Void
    typealias SubmitLink = @MainActor (URL, @escaping LinkCompletion) -> Void

    @Published private(set) var cards: [HangerCard]
    @Published private(set) var preferences: HangerPreferences
    @Published private(set) var diagnostic: String
    var onAutoReveal: (() -> Void)?

    private let scanner = CodexScanner()
    private let remoteFeed = CodexRemoteFeed()
    private let stateFile: HangerStateFile
    private let submitLink: SubmitLink
    private var timer: DispatchSourceTimer?
    private var scanInFlight = false
    private var monitorGeneration = 0
    private var hasScannedLocalActivity = false
    private var shouldRestoreUnread = true
    private var openRequestID: UUID?
    private var state: HangerState
    private var localRecentCandidates: [HangerCard] = []
    private var remoteRecentCandidates: [HangerCard] = []
    private var remoteTerminalTurns: [String: String] = [:]
    private var sourceDiagnostic = "正在检查本机 Codex 数据"
    private var actionDiagnostic: String?
    private var storageDiagnostic: String?
    private let writableState: Bool

    init(stateFile: HangerStateFile, submitLink: SubmitLink? = nil) {
        self.stateFile = stateFile
        self.submitLink = submitLink ?? Self.submitToWorkspace
        do {
            state = try stateFile.read()
            writableState = true
            diagnostic = sourceDiagnostic
        } catch {
            state = HangerState()
            writableState = false
            storageDiagnostic = "设备状态文件无法读取，已保留原文件"
            diagnostic = storageDiagnostic ?? sourceDiagnostic
        }
        preferences = state.preferences
        cards = state.cards.filter(\.isUnread)
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .seconds(2), leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.scan() }
        self.timer = timer
        timer.resume()
        if !preferences.isMonitoring {
            sourceDiagnostic = "数据监听已关闭"
            updateDiagnostic()
        }
    }

    func stop() {
        openRequestID = nil
        monitorGeneration += 1
        timer?.cancel()
        timer = nil
        remoteFeed.stop()
        persist()
    }

    func setPaused(_ value: Bool) {
        guard state.preferences.isPaused != value else { return }
        state.preferences.isPaused = value
        preferences = state.preferences
        persist()
        if !value && state.hasPendingNotifications {
            shouldRestoreUnread = false
            onAutoReveal?()
        }
    }

    func setMonitoring(_ value: Bool) {
        guard state.preferences.isMonitoring != value else { return }
        state.preferences.isMonitoring = value
        preferences = state.preferences
        monitorGeneration += 1
        persist()
        if value {
            scan()
        } else {
            openRequestID = nil
            remoteFeed.stop()
            hasScannedLocalActivity = false
            localRecentCandidates = []
            remoteRecentCandidates = []
            remoteTerminalTurns = [:]
            refreshCards()
            sourceDiagnostic = "数据监听已关闭"
            updateDiagnostic()
        }
    }

    func setHighlightSeconds(_ value: Double) {
        guard value.isFinite else { return }
        state.preferences.highlightSeconds = min(max(value, 1), 30)
        preferences = state.preferences
        persist()
    }

    func setRecentThreadCount(_ value: Int) {
        let count = min(max(0, value), HangerPreferences.maximumRecentThreadCount)
        guard state.preferences.recentThreadCount != count else { return }
        state.preferences.recentThreadCount = count
        preferences = state.preferences
        refreshCards()
        persist()
        scan()
    }

    @discardableResult
    func markRead(_ card: HangerCard) -> Bool {
        var updated = state
        guard updated.markRead(card), writableState else { return false }
        do {
            try stateFile.write(updated)
            storageDiagnostic = nil
        } catch {
            storageDiagnostic = "无法保存已读状态，卡片仍然保留"
            updateDiagnostic()
            return false
        }
        state = updated
        refreshCards()
        updateDiagnostic()
        return true
    }

    func open(_ card: HangerCard, collapse: @escaping () -> Void) {
        let requestID = UUID()
        openRequestID = requestID
        guard let url = HangerLink.url(for: card.id, hostID: card.hostID) else {
            actionDiagnostic = "无法找到 Codex 的会话打开入口"
            updateDiagnostic()
            return
        }
        let originalCards = cards
        let requestedAt = Date()
        submitLink(url) { [weak self] result in
            guard let self, self.openRequestID == requestID else { return }
            switch result {
            case .noHandler:
                self.actionDiagnostic = "无法找到 Codex 的会话打开入口"
            case .failed:
                self.actionDiagnostic = "未能打开 Codex 会话，可以再次点击重试"
            case let .accepted(application):
                self.actionDiagnostic = nil
                if HangerLink.shouldHide(card: card, originalCards: originalCards, currentCards: self.cards) {
                    collapse()
                }
                if card.isUnread {
                    self.confirmOpened(
                        card, application: application, requestedAt: requestedAt,
                        requestID: requestID
                    )
                }
            }
            self.updateDiagnostic()
        }
    }

    private static func submitToWorkspace(_ url: URL, completion: @escaping LinkCompletion) {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            completion(.noHandler)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { application, error in
            DispatchQueue.main.async {
                guard error == nil, let application else {
                    completion(.failed)
                    return
                }
                completion(.accepted(application))
            }
        }
    }

    private func confirmOpened(
        _ card: HangerCard, application: NSRunningApplication, requestedAt: Date, requestID: UUID
    ) {
        Task { [weak self] in
            guard let self else { return }
            if let processStartedAt = application.launchDate {
                let pid = application.processIdentifier
                for _ in 0..<12 {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard self.openRequestID == requestID, !application.isTerminated else { return }
                    guard application.isActive, self.hasOneVisibleWindow(processID: pid) else { continue }

                    guard self.confirmsRemoteIdentity(of: card) else { continue }
                    let confirmed = await self.scanner.confirmsOpening(
                        threadID: card.id, hostID: card.hostID, processID: pid,
                        processStartedAt: processStartedAt, requestedAt: requestedAt
                    )
                    guard self.openRequestID == requestID else { return }
                    guard confirmed, self.confirmsRemoteIdentity(of: card),
                          application.isActive, self.hasOneVisibleWindow(processID: pid) else { continue }

                    self.markRead(card)
                    return
                }
            }
            guard self.openRequestID == requestID else { return }
            self.actionDiagnostic = "未能确认目标对话已打开，保留未读。可再次点击重试。"
            self.updateDiagnostic()
        }
    }

    private func confirmsRemoteIdentity(of card: HangerCard) -> Bool {
        guard let hostID = card.hostID else { return true }
        guard preferences.isMonitoring else { return false }
        let matching = remoteFeed.threads().filter { $0.threadID == card.id }
        return matching.count == 1 && matching.first?.hostID == hostID
    }

    private func hasOneVisibleWindow(processID: Int32) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return false }
        return windows.filter { window in
            guard window[kCGWindowOwnerPID as String] as? Int32 == processID,
                  window[kCGWindowLayer as String] as? Int == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 0) > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any] else { return false }
            return (bounds["Width"] as? Double ?? 0) >= 200 && (bounds["Height"] as? Double ?? 0) >= 150
        }.count == 1
    }

    private func scan() {
        guard preferences.isMonitoring, !scanInFlight else { return }
        scanInFlight = true
        let generation = monitorGeneration
        let tracked = state.trackedTurnIDs
        let waiting = state.trackedWaitingRequests
        let recentCount = preferences.recentThreadCount
        _ = remoteFeed.threads()
        let scanner = self.scanner
        let desktopStartedAt = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
            .compactMap(\.launchDate).max() ?? .distantFuture
        Task(priority: .utility) { [weak self] in
            let snapshot = await scanner.read(
                tracked, desktopStartedAt: desktopStartedAt, waiting: waiting, recentCount: recentCount
            )
            self?.receive(snapshot, generation: generation)
        }
    }

    private func receive(_ snapshot: CodexScanner.Snapshot, generation: Int) {
        scanInFlight = false
        guard monitorGeneration == generation, preferences.isMonitoring else { return }
        if let recent = snapshot.recentCandidates { localRecentCandidates = recent }
        let remoteThreads = remoteFeed.threads()
        remoteRecentCandidates = remoteThreads.map { thread in
            HangerCard.recent(
                threadID: thread.threadID, hostID: thread.hostID, title: thread.title,
                projectName: remoteProjectName(thread), changedAt: thread.updatedAt
            )
        }
        let remoteAlert = state.apply(remoteObservations(from: remoteThreads), scope: .remote)
        sourceDiagnostic = snapshot.diagnostic
        defer { updateDiagnostic() }
        let localAlert: Bool
        switch snapshot.observations {
        case let .success(observations):
            hasScannedLocalActivity = true
            localAlert = state.apply(observations)
        case .failure:
            if sourceDiagnostic.isEmpty { sourceDiagnostic = "无法读取本机 Codex 数据，稍后自动重试" }
            localAlert = false
        }
        if !remoteThreads.isEmpty {
            sourceDiagnostic += " 已读取 \(remoteThreads.count) 个已加载的 Codex Remote 会话。"
        }
        refreshCards()
        persist()
        revealIfNeeded(newNotification: localAlert || remoteAlert)
    }

    private func remoteObservations(from threads: [CodexRemoteThread]) -> [ThreadObservation] {
        let tracked = state.remoteTrackedTurnIDs
        let activeIdentities = Set(threads.map {
            ThreadObservation.identity(threadID: $0.threadID, hostID: $0.hostID)
        })
        remoteTerminalTurns = remoteTerminalTurns.filter { activeIdentities.contains($0.key) }
        return threads.flatMap { thread -> [ThreadObservation] in
            let identity = ThreadObservation.identity(threadID: thread.threadID, hostID: thread.hostID)
            let turns = thread.turnsForObservation(trackedTurnID: tracked[identity])
            guard let observed = turns.last else { return [] }
            var observations = turns.map { turn in
                ThreadObservation(
                    threadID: thread.threadID, title: thread.title, projectName: remoteProjectName(thread),
                    turnID: turn.turnID, status: turn.status, updatedAt: turn.happenedAt,
                    requestID: turn.requestID, hostID: thread.hostID
                )
            }
            if observed.status == .completed || observed.status == .failed {
                let alreadySeen = remoteTerminalTurns[identity] == observed.turnID
                remoteTerminalTurns[identity] = observed.turnID
                if !alreadySeen, !observed.hadPendingInputAfterCompletion, let terminal = observations.last,
                   let running = Self.shortRemoteTurnStart(
                       for: terminal, trackedTurnID: tracked[identity], observedActiveAt: observed.observedActiveAt
                   ) {
                    observations.insert(running, at: observations.count - 1)
                }
                if observed.status == .completed, observed.asksForReply,
                   tracked[identity] == observed.turnID || observed.observedActiveAt != nil {
                    let index = observations.count - 1
                    observations[index].status = .waiting
                    observations[index].requestID = CodexFollowUpQuestion.requestID(for: observed.turnID)
                }
            }
            return observations
        }
    }

    // A short turn can start and finish between two runtime scans.
    static func shortRemoteTurnStart(
        for terminal: ThreadObservation, trackedTurnID: String?, observedActiveAt: Date?
    ) -> ThreadObservation? {
        guard trackedTurnID != terminal.turnID, let observedActiveAt else { return nil }
        var running = terminal
        running.status = .running
        running.updatedAt = min(observedActiveAt, terminal.updatedAt)
        return running
    }

    private func remoteProjectName(_ thread: CodexRemoteThread) -> String {
        let folder = thread.cwd.split { $0 == "/" || $0 == "\\" }.last
        return folder.map { "远程 · \($0)" } ?? "Codex Remote"
    }

    private func revealIfNeeded(newNotification: Bool) {
        let showRestored = shouldRestoreUnread && state.hasPendingNotifications && !preferences.isPaused
        shouldRestoreUnread = false
        if newNotification || showRestored { onAutoReveal?() }
    }

    private func refreshCards() {
        let candidates = (localRecentCandidates + remoteRecentCandidates).sorted {
            $0.changedAt == $1.changedAt ? $0.identity < $1.identity : $0.changedAt > $1.changedAt
        }
        let remoteIdentities = Set(remoteRecentCandidates.map(\.identity))
        let updated = state.cards(includingRecent: candidates).filter {
            $0.isUnread || ($0.hostID == nil ? hasScannedLocalActivity : remoteIdentities.contains($0.identity))
        }
        if updated != cards { cards = updated }
    }

    private func persist() {
        guard writableState else { return }
        do {
            try stateFile.write(state)
            storageDiagnostic = nil
        } catch {
            storageDiagnostic = "无法保存设备状态，未读通知可能在重启后丢失"
        }
        updateDiagnostic()
    }

    private func updateDiagnostic() {
        let updated = [storageDiagnostic, actionDiagnostic, sourceDiagnostic]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        if updated != diagnostic { diagnostic = updated }
    }
}
