import Foundation

public final class CodexSource {
    private struct Thread {
        var id: String
        var name: String
        var cwd: String
        var rolloutPath: String
        var updatedAt: Date?
    }

    private struct Turn {
        var id: String
        var status: String
        var startedAt: Date?
        var completedAt: Date?
    }

    private static let liveWindow: TimeInterval = 10 * 60
    private static let discoveryWindow: TimeInterval = 24 * 60 * 60
    private static let waitingDiagnostic = "已监听本机 Codex 的待回答请求和明确追问。本机审批等待暂无可验证的只读来源。"
    private static let uuidPattern = [8, 4, 4, 4, 12]
        .map { String(repeating: "[0-9A-Fa-f]", count: $0) }.joined(separator: "-")

    private let home: URL
    private let projects = CodexProjectNames()
    private let stopLogs: CodexStopLogs
    private let rollouts: CodexRolloutTail

    public private(set) var diagnostic = ""

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) {
        self.home = home
        rollouts = CodexRolloutTail(sessionsDirectory: home.appendingPathComponent("sessions"))
        stopLogs = CodexStopLogs(
            directory: home.deletingLastPathComponent().appendingPathComponent("Library/Logs/com.openai.codex")
        )
    }

    public func containsLocalThread(_ threadID: String) -> Bool {
        guard UUID(uuidString: threadID) != nil,
              let metadata = try? CodexReadOnlyDatabase(url: home.appendingPathComponent("state_5.sqlite")) else {
            return false
        }
        let matches = try? metadata.rows(
            """
            SELECT 1 FROM threads
            WHERE id = ? AND archived = 0 AND originator = 'Codex Desktop' AND source = 'vscode'
            """,
            [threadID], map: { _ in true }
        )
        return matches?.first == true
    }

    public func recentCards(limit: Int) throws -> [HangerCard] {
        guard limit > 0 else { return [] }
        let metadata = try CodexReadOnlyDatabase(url: home.appendingPathComponent("state_5.sqlite"))
        let (selectThread, _) = try Self.threadSelection(from: metadata)
        let threads = try metadata.rows(
            selectThread + """

            AND length(CAST(id AS BLOB)) = 36 AND id GLOB ?
            ORDER BY effective_updated_at DESC, id COLLATE BINARY ASC
            LIMIT ?
            """,
            [Self.uuidPattern, String(limit)], map: Self.readThread
        )
        projects.refresh(from: home.appendingPathComponent(".codex-global-state.json"))
        return threads.map { thread in
            let changedAt = thread.updatedAt ?? .distantPast
            return HangerCard(
                id: thread.id, turnID: "", title: thread.name,
                projectName: projects.name(threadID: thread.id, cwd: thread.cwd),
                status: .unknown, changedAt: changedAt, highlightStartedAt: changedAt,
                notificationID: nil, isRecent: true
            )
        }
    }

    public func scan(trackedThreadIDs: Set<String>, now: Date = Date()) throws -> [ThreadObservation] {
        try scan(trackedThreadIDs: trackedThreadIDs, trackedTurnIDsByThread: [:], now: now)
    }

    public func scan(
        trackedThreadIDs: Set<String>,
        trackedTurnIDsByThread: [String: String],
        now: Date = Date(),
        desktopStartedAt: Date? = nil,
        trackedWaitingRequests: [String: String] = [:]
    ) throws -> [ThreadObservation] {
        do {
            let observations = try read(
                tracked: trackedThreadIDs.union(trackedTurnIDsByThread.keys),
                exactTurns: trackedTurnIDsByThread,
                now: now, desktopStartedAt: desktopStartedAt, trackedWaitingRequests: trackedWaitingRequests
            )
            diagnostic = Self.waitingDiagnostic
            return observations
        } catch {
            diagnostic = error.localizedDescription
            throw error
        }
    }

    private func read(
        tracked: Set<String>,
        exactTurns: [String: String],
        now: Date,
        desktopStartedAt: Date?,
        trackedWaitingRequests: [String: String]
    ) throws -> [ThreadObservation] {
        let metadata = try CodexReadOnlyDatabase(url: home.appendingPathComponent("state_5.sqlite"))
        let history = try CodexReadOnlyDatabase(url: home.appendingPathComponent("thread_history_1.sqlite"))
        let (selectThread, hasMilliseconds) = try Self.threadSelection(from: metadata)
        let turnColumns = try history.columns("thread_turns", required: [
            "thread_id", "turn_id", "rollout_ordinal", "status", "started_at", "completed_at"
        ])

        let cutoff = now.addingTimeInterval(-Self.discoveryWindow).timeIntervalSince1970
        let recencyFilter = hasMilliseconds
            ? "(updated_at_ms >= CAST(? AS INTEGER) OR (updated_at_ms IS NULL AND updated_at >= CAST(? AS INTEGER)))"
            : "updated_at >= CAST(? AS INTEGER)"
        let cutoffSeconds = String(Int64(cutoff.rounded(.down)))
        let cutoffs = hasMilliseconds
            ? [String(Int64((cutoff * 1000).rounded(.down))), cutoffSeconds]
            : [cutoffSeconds]
        var candidates = try metadata.rows(selectThread + " AND " + recencyFilter, cutoffs, map: Self.readThread)
        let discovered = Set(candidates.map(\.id))
        for id in tracked.subtracting(discovered) {
            candidates.append(contentsOf: try metadata.rows(selectThread + " AND id = ?", [id], map: Self.readThread))
        }

        projects.refresh(from: home.appendingPathComponent(".codex-global-state.json"))
        let rootTurn = turnColumns.contains("root_turn_id") ? " AND (root_turn_id IS NULL OR root_turn_id=turn_id)" : ""
        let selectTurn = """
            SELECT turn_id, status, started_at, completed_at FROM thread_turns
            WHERE thread_id=?\(rootTurn)
            """
        let readTurn: (OpaquePointer) -> Turn = { row in
            Turn(
                id: CodexReadOnlyDatabase.text(row, 0) ?? "",
                status: CodexReadOnlyDatabase.text(row, 1) ?? "",
                startedAt: CodexReadOnlyDatabase.timestamp(row, 2),
                completedAt: CodexReadOnlyDatabase.timestamp(row, 3)
            )
        }
        var observations: [ThreadObservation] = []
        let liveCutoff = now.addingTimeInterval(-Self.liveWindow)
        var streaming = Set<String>()
        for thread in candidates.sorted(by: { $0.id < $1.id }) where !thread.id.isEmpty {
            let latest = try history.rows(
                selectTurn + " ORDER BY rollout_ordinal DESC LIMIT 1", [thread.id], map: readTurn
            ).first
            let project = projects.name(threadID: thread.id, cwd: thread.cwd)
            let trackedTurnID = exactTurns[thread.id]
            let expectedRequest = trackedWaitingRequests[thread.id]
            let hasTrackedFollowUp = expectedRequest.map(CodexFollowUpQuestion.isRequestID) ?? false
            let hasTrackedAsync = CodexRolloutTail.isAsyncInputRequest(expectedRequest)
            let trackedDiffersFromLatest = trackedTurnID != nil && trackedTurnID != latest?.id
            var rolloutDate: Date?
            var rolloutTurn: Turn?
            var endedLatestTurn = false
            var hasNewerRolloutTurn = false
            var missingTrackedTurn = false
            let canDiscoverFromRollout = trackedTurnID != nil || (thread.updatedAt ?? .distantPast) >= liveCutoff
            let mayBeWaiting = latest?.status == "inProgress"
            let oldestWait = desktopStartedAt ?? now.addingTimeInterval(-Self.discoveryWindow)
            if canDiscoverFromRollout || mayBeWaiting,
               let candidateDate = modificationDate(of: thread.rolloutPath),
               candidateDate >= liveCutoff || (mayBeWaiting && candidateDate >= oldestWait)
                || hasTrackedFollowUp || hasTrackedAsync || trackedDiffersFromLatest {
                let hint = rollouts.latestStart(
                    threadID: thread.id, rolloutPath: thread.rolloutPath, trackedTurnID: trackedTurnID,
                    expectedAsyncRequestID: hasTrackedAsync ? expectedRequest : nil
                )
                if rollouts.verifiedSession(for: thread.id) {
                    streaming.insert(thread.id)
                    if canDiscoverFromRollout { rolloutDate = candidateDate }
                }
                if canDiscoverFromRollout, let hint {
                    let isTracked = trackedTurnID == hint.turnID
                    endedLatestTurn = hint.turnID == latest?.id && hint.ended && !isTracked
                    if hint.date <= now, hint.turnID != latest?.id,
                       isTracked || (hint.date >= liveCutoff && !hint.ended) || hasTrackedFollowUp,
                       hint.date >= (latest?.startedAt ?? .distantPast),
                       try history.rows(
                           "SELECT 1 FROM thread_turns WHERE thread_id=? AND turn_id=?",
                           [thread.id, hint.turnID], map: { _ in true }
                       ).isEmpty {
                        hasNewerRolloutTurn = true
                        if isTracked, let completedAt = hint.completedAt, completedAt <= now {
                            rolloutTurn = Turn(id: hint.turnID, status: "completed", startedAt: hint.date, completedAt: completedAt)
                        } else if !hint.ended, candidateDate >= liveCutoff, isTracked || hint.date >= liveCutoff {
                            rolloutTurn = Turn(id: hint.turnID, status: "inProgress", startedAt: hint.date, completedAt: nil)
                        }
                    }
                }
            }
            if streaming.contains(thread.id), let pending = rollouts.asyncWait(
                threadID: thread.id, since: max(liveCutoff, oldestWait), now: now, expectedRequestID: expectedRequest
            ) {
                let projected = rolloutTurn ?? latest
                let changedAt = Date(timeIntervalSince1970: floor(pending.changedAt.timeIntervalSince1970))
                observations.append(ThreadObservation(
                    threadID: thread.id, title: thread.name, projectName: project, turnID: pending.turnID,
                    status: .waiting, updatedAt: min(max(changedAt, projected?.completedAt ?? projected?.startedAt ?? .distantPast), now),
                    requestID: pending.requestID
                ))
                continue
            }
            if let trackedTurnID, hasTrackedAsync, rollouts.asyncResolvedAt(
                threadID: thread.id, turnID: trackedTurnID, now: now, expectedRequestID: expectedRequest
            ) == nil {
                observations.append(ThreadObservation(
                    threadID: thread.id, title: thread.name, projectName: project,
                    turnID: trackedTurnID, status: .unknown, updatedAt: now
                ))
                continue
            }
            if let trackedTurnID, trackedTurnID != latest?.id {
                if let trackedTurn = try history.rows(
                    selectTurn + " AND turn_id=?", [thread.id, trackedTurnID], map: readTurn
                ).first {
                    observations.append(observation(
                        thread: thread, turn: trackedTurn, project: project, isLatest: false, rolloutDate: nil, now: now,
                        expectedRequestID: hasTrackedFollowUp ? expectedRequest : nil,
                        asyncResolvedAt: rollouts.asyncResolvedAt(threadID: thread.id, turnID: trackedTurn.id, now: now)
                    ))
                } else if trackedTurnID != rolloutTurn?.id {
                    missingTrackedTurn = true
                    // The file's activity is not evidence for this particular turn.
                    observations.append(ThreadObservation(
                        threadID: thread.id, title: thread.name, projectName: project,
                        turnID: trackedTurnID, status: .unknown, updatedAt: now
                    ))
                }
            }
            if let latest, !latest.id.isEmpty, rolloutTurn == nil || trackedTurnID == latest.id {
                observations.append(observation(
                    thread: thread, turn: latest, project: project,
                    isLatest: !hasNewerRolloutTurn && !endedLatestTurn && !missingTrackedTurn,
                    rolloutDate: missingTrackedTurn ? nil : rolloutDate, now: now,
                    canReadInput: streaming.contains(thread.id), desktopStartedAt: desktopStartedAt,
                    expectedRequestID: trackedTurnID == latest.id && !hasTrackedAsync ? expectedRequest : nil,
                    isTracked: trackedTurnID == latest.id,
                    asyncResolvedAt: rollouts.asyncResolvedAt(threadID: thread.id, turnID: latest.id, now: now)
                ))
            }
            if let rolloutTurn {
                observations.append(observation(
                    thread: thread, turn: rolloutTurn, project: project,
                    isLatest: true, rolloutDate: rolloutDate, now: now,
                    canReadInput: streaming.contains(thread.id), desktopStartedAt: desktopStartedAt,
                    expectedRequestID: trackedTurnID == rolloutTurn.id && !hasTrackedAsync ? expectedRequest : nil,
                    isTracked: trackedTurnID == rolloutTurn.id,
                    asyncResolvedAt: rollouts.asyncResolvedAt(threadID: thread.id, turnID: rolloutTurn.id, now: now)
                ))
            }
        }
        rollouts.keepThreads(streaming)
        return observations
    }

    private static func threadSelection(from metadata: CodexReadOnlyDatabase) throws -> (String, Bool) {
        let columns = try metadata.columns("threads", required: [
            "id", "cwd", "rollout_path", "originator", "source", "thread_source", "updated_at", "archived"
        ])
        let hasMilliseconds = columns.contains("updated_at_ms")
        let timestamp = hasMilliseconds ? "COALESCE(updated_at_ms, updated_at * 1000)" : "updated_at * 1000"
        let shortTitle = columns.contains("name") ? "name" : "NULL"
        let parentThread = columns.contains("attached_thread_parent_id") ? " AND attached_thread_parent_id IS NULL" : ""
        let query = """
            SELECT id, \(shortTitle), cwd, rollout_path, \(timestamp) AS effective_updated_at FROM threads
            WHERE originator='Codex Desktop' AND source='vscode' AND thread_source='user' AND archived=0\(parentThread)
            """
        return (query, hasMilliseconds)
    }

    private static func readThread(_ row: OpaquePointer) -> Thread {
        let name = CodexReadOnlyDatabase.text(row, 1)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Thread(
            id: CodexReadOnlyDatabase.text(row, 0) ?? "",
            name: name.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled thread",
            cwd: CodexReadOnlyDatabase.text(row, 2) ?? "",
            rolloutPath: CodexReadOnlyDatabase.text(row, 3) ?? "",
            updatedAt: CodexReadOnlyDatabase.timestamp(row, 4, scale: 1000)
        )
    }

    private func observation(
        thread: Thread,
        turn: Turn,
        project: String,
        isLatest: Bool,
        rolloutDate: Date?,
        now: Date,
        canReadInput: Bool = false,
        desktopStartedAt: Date? = nil,
        expectedRequestID: String? = nil,
        isTracked: Bool = false,
        asyncResolvedAt: Date? = nil
    ) -> ThreadObservation {
        let status: ThreadStatus
        var updatedAt = turn.completedAt ?? turn.startedAt ?? .distantPast
        var requestID: String?

        switch turn.status {
        case "inProgress":
            if let desktopStartedAt,
               desktopStartedAt > now ||
               max(turn.startedAt ?? .distantPast, rolloutDate ?? .distantPast) < desktopStartedAt {
                status = .unknown
                updatedAt = now
                break
            }
            let liveCutoff = now.addingTimeInterval(-Self.liveWindow)
            let projectedRecentStart = (turn.startedAt ?? .distantPast) >= liveCutoff
            let activeRollout = (rolloutDate ?? .distantPast) >= liveCutoff
            let input = isLatest && canReadInput ? turn.startedAt.flatMap {
                rollouts.inputActivity(
                    threadID: thread.id, turnID: turn.id, turnStartedAt: $0,
                    desktopStartedAt: desktopStartedAt, now: now, expectedRequestID: expectedRequestID
                )
            } : nil
            if let input {
                // The SQLite terminal timestamp is stored in whole seconds.
                updatedAt = max(updatedAt, Date(timeIntervalSince1970: floor(input.changedAt.timeIntervalSince1970)))
                requestID = input.requestID
            }
            if requestID != nil {
                status = .waiting
            } else if expectedRequestID != nil, input == nil {
                status = .unknown
                updatedAt = now
            } else {
                status = isLatest && (projectedRecentStart || activeRollout) ? .running : .unknown
            }
        case "completed":
            let followUpID = CodexFollowUpQuestion.requestID(for: turn.id)
            let knownFollowUp = expectedRequestID == followUpID
            let launchSecond = desktopStartedAt.map { Date(timeIntervalSince1970: floor($0.timeIntervalSince1970)) }
            if isLatest, isTracked, canReadInput, asyncResolvedAt == nil,
               let askedAt = rollouts.completedFollowUpDate(threadID: thread.id, turnID: turn.id), askedAt <= now,
               knownFollowUp || askedAt >= max(now.addingTimeInterval(-Self.liveWindow), launchSecond ?? .distantPast) {
                status = .waiting
                requestID = followUpID
                // A new turn can start in the same second as the final question.
                updatedAt = turn.completedAt ?? Date(timeIntervalSince1970: floor(askedAt.timeIntervalSince1970))
            } else if knownFollowUp {
                // Do not turn an already reported question into a completion alert.
                status = .unknown
                updatedAt = now
            } else {
                status = .completed
            }
        case "failed":
            status = .failed
        case "interrupted":
            if let completedAt = turn.completedAt, stopLogs.confirmsUserStop(
                threadID: thread.id, turnID: turn.id, completedAt: completedAt, now: now
            ) {
                status = .interrupted
            } else {
                status = .unknown
            }
        default:
            status = .unknown
        }

        if let asyncResolvedAt {
            updatedAt = max(updatedAt, Date(timeIntervalSince1970: floor(asyncResolvedAt.timeIntervalSince1970)))
        }

        return ThreadObservation(
            threadID: thread.id, title: thread.name, projectName: project,
            turnID: turn.id, status: status, updatedAt: min(updatedAt, now), requestID: requestID
        )
    }

    private func modificationDate(of path: String) -> Date? {
        guard path.hasPrefix("/"), path.hasSuffix(".jsonl") else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.modificationDate] as? Date
    }
}
