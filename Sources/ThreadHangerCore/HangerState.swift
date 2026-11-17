import Foundation

public enum ThreadStatus: String, Codable, Sendable {
    case running, waiting, completed, failed, interrupted, unknown

    var isActive: Bool { self == .running || self == .waiting }

    var canNotify: Bool { self == .waiting || self == .completed || self == .failed }
}

public struct ThreadObservation: Codable, Equatable, Sendable {
    public var threadID: String
    public var title: String
    public var projectName: String
    public var turnID: String
    public var status: ThreadStatus
    public var updatedAt: Date
    public var requestID: String?
    public var hostID: String?

    public var identity: String { Self.identity(threadID: threadID, hostID: hostID) }

    public static func identity(threadID: String, hostID: String?) -> String {
        hostID.map { "\($0)/\(threadID)" } ?? threadID
    }

    public init(
        threadID: String,
        title: String,
        projectName: String,
        turnID: String,
        status: ThreadStatus,
        updatedAt: Date,
        requestID: String? = nil,
        hostID: String? = nil
    ) {
        self.threadID = threadID
        self.title = title
        self.projectName = projectName
        self.turnID = turnID
        self.status = status
        self.updatedAt = updatedAt
        self.requestID = requestID
        self.hostID = hostID
    }
}

public struct HangerPreferences: Codable, Equatable, Sendable {
    public static let maximumRecentThreadCount = 10
    private static let defaultRecentThreadCount = 5

    public var isPaused: Bool
    public var isMonitoring: Bool
    public var highlightSeconds: Double
    public var recentThreadCount: Int {
        didSet { recentThreadCount = Self.clampedRecentThreadCount(recentThreadCount) }
    }

    init(isPaused: Bool = false, isMonitoring: Bool = true, highlightSeconds: Double = 5) {
        self.isPaused = isPaused
        self.isMonitoring = isMonitoring
        self.highlightSeconds = highlightSeconds
        self.recentThreadCount = Self.defaultRecentThreadCount
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isPaused = try values.decode(Bool.self, forKey: .isPaused)
        isMonitoring = try values.decode(Bool.self, forKey: .isMonitoring)
        highlightSeconds = try values.decode(Double.self, forKey: .highlightSeconds)
        recentThreadCount = Self.clampedRecentThreadCount(
            try values.decodeIfPresent(Int.self, forKey: .recentThreadCount) ?? Self.defaultRecentThreadCount
        )
    }

    private static func clampedRecentThreadCount(_ count: Int) -> Int {
        min(max(0, count), maximumRecentThreadCount)
    }
}

public struct HangerCard: Identifiable, Equatable, Sendable {
    public let id: String
    public let turnID: String
    public let title: String
    public let projectName: String
    public let status: ThreadStatus
    public let changedAt: Date
    public let highlightStartedAt: Date
    let notificationID: UUID?
    public internal(set) var isRecent = false
    public internal(set) var hostID: String? = nil

    public var identity: String { ThreadObservation.identity(threadID: id, hostID: hostID) }
    public var isUnread: Bool { notificationID != nil }

    public static func recent(
        threadID: String, hostID: String? = nil, title: String, projectName: String, changedAt: Date
    ) -> Self {
        Self(
            id: threadID, turnID: "", title: title, projectName: projectName, status: .unknown,
            changedAt: changedAt, highlightStartedAt: changedAt, notificationID: nil,
            isRecent: true, hostID: hostID
        )
    }

    public func isHighlighted(until duration: Double, now: Date) -> Bool {
        status == .waiting || (isUnread && now < highlightStartedAt.addingTimeInterval(duration))
    }
}

public enum HangerObservationScope: Sendable {
    case local, remote

    fileprivate func includes(hostID: String?) -> Bool {
        switch self {
        case .local: return hostID == nil
        case .remote: return hostID != nil
        }
    }
}

public struct HangerState: Codable {
    private struct Checkpoint: Codable {
        var turnID: String
        var requestID: String?
        var status: ThreadStatus
        var observedAt: Date
        var changedAt: Date
        var highlightStartedAt: Date
        var notificationID: UUID?
        var hostID: String?
        var threadID: String?
        var missingSince: Date?

        mutating func markUnknown(at now: Date) {
            status = .unknown
            if hostID != nil, missingSince == nil {
                missingSince = now
            }
        }
    }

    private struct Label {
        var title: String
        var project: String
    }

    public var preferences = HangerPreferences()
    private var checkpoints: [String: Checkpoint] = [:]
    private var labels: [String: Label] = [:]

    private enum CodingKeys: String, CodingKey {
        case preferences, checkpoints
    }

    public init() {}

    public var trackedTurnIDs: [String: String] {
        checkpoints.compactMapValues { $0.hostID == nil ? $0.turnID : nil }
    }

    public var trackedWaitingRequests: [String: String] {
        checkpoints.compactMapValues { $0.hostID == nil ? $0.requestID : nil }
    }

    public var remoteTrackedTurnIDs: [String: String] {
        checkpoints.compactMapValues { $0.hostID != nil ? $0.turnID : nil }
    }

    public var activeThreadIDs: Set<String> {
        Set(checkpoints.compactMap { id, checkpoint in checkpoint.status.isActive ? id : nil })
    }

    public func cards(includingRecent candidates: [HangerCard]) -> [HangerCard] {
        let current = cards
        guard preferences.isMonitoring else { return current.filter(\.isUnread) }
        guard preferences.recentThreadCount > 0 else { return current }
        var seen = activeThreadIDs.union(current.map(\.identity))
        var recent: [HangerCard] = []
        for candidate in candidates where seen.insert(candidate.identity).inserted {
            recent.append(candidate)
            if recent.count == preferences.recentThreadCount { break }
        }
        return current + recent
    }

    public var hasPendingNotifications: Bool {
        checkpoints.values.contains { $0.status.canNotify && $0.notificationID != nil }
    }

    public var cards: [HangerCard] {
        checkpoints.compactMap { id, checkpoint -> HangerCard? in
            guard checkpoint.status == .running || (checkpoint.status.canNotify && checkpoint.notificationID != nil)
            else { return nil }
            let label = labels[id]
            let threadID = checkpoint.threadID ?? id
            return HangerCard(
                id: threadID,
                turnID: checkpoint.turnID,
                title: label?.title ?? String(threadID.prefix(12)),
                projectName: label?.project ?? "Codex",
                status: checkpoint.status,
                changedAt: checkpoint.changedAt,
                highlightStartedAt: checkpoint.highlightStartedAt,
                notificationID: checkpoint.notificationID,
                hostID: checkpoint.hostID
            )
        }.sorted {
            $0.changedAt == $1.changedAt ? $0.identity < $1.identity : $0.changedAt > $1.changedAt
        }
    }

    /// A scan orders a tracked older turn before the thread’s current turn.
    /// Reveal only notifications that survive all observations in the scan.
    @discardableResult
    public mutating func apply(
        _ observations: [ThreadObservation], scope: HangerObservationScope = .local, now: Date = Date()
    ) -> Bool {
        var newNotifications = Set<UUID>()
        var observedThreadIDs = Set<String>()
        for observation in observations where scope.includes(hostID: observation.hostID) {
            observedThreadIDs.insert(observation.identity)
            if let notification = reconcile(observation, now: now) {
                newNotifications.insert(notification)
            }
        }
        for (id, var checkpoint) in checkpoints where scope.includes(hostID: checkpoint.hostID)
                && (checkpoint.status == .running || (scope == .remote && checkpoint.status == .waiting))
                && !observedThreadIDs.contains(id) {
            checkpoint.markUnknown(at: now)
            checkpoints[id] = checkpoint
        }
        for (id, checkpoint) in checkpoints where scope.includes(hostID: checkpoint.hostID)
                && checkpoint.status == .unknown
                && now.timeIntervalSince(checkpoint.missingSince ?? checkpoint.observedAt) > 2 * 24 * 60 * 60 {
            checkpoints.removeValue(forKey: id)
            labels.removeValue(forKey: id)
        }
        let visibleNotifications = checkpoints.values.filter { $0.status.canNotify }.compactMap(\.notificationID)
        return !preferences.isPaused && !newNotifications.isDisjoint(with: visibleNotifications)
    }

    @discardableResult
    public mutating func markRead(_ card: HangerCard) -> Bool {
        let id = card.identity
        guard let notification = card.notificationID,
              var checkpoint = checkpoints[id], checkpoint.status.canNotify,
              checkpoint.notificationID == notification else { return false }
        if checkpoint.status == .waiting {
            checkpoint.notificationID = nil
            checkpoints[id] = checkpoint
        } else {
            checkpoints.removeValue(forKey: id)
            labels.removeValue(forKey: id)
        }
        return true
    }

    private mutating func reconcile(_ observation: ThreadObservation, now: Date) -> UUID? {
        let id = observation.identity
        let previous = checkpoints[id]
        let sameTurn = previous?.turnID == observation.turnID
        let status = observation.status
        let isFinalQuestion = status == .waiting && CodexFollowUpQuestion.isRequestID(observation.requestID)
        let startsTracking = status.isActive && !isFinalQuestion

        // The thread metadata comes from the current scan even when its turn projection is older.
        guard previous != nil || startsTracking else { return nil }
        labels[id] = Label(title: observation.title, project: observation.projectName)

        // A finalized question, like any other terminal observation, must belong to a tracked turn.
        guard sameTurn || startsTracking else { return nil }
        if let previous {
            guard observation.updatedAt >= previous.observedAt else { return nil }
            if sameTurn, (status == .completed || isFinalQuestion),
               CodexRemoteStream.isNonblockingInput(previous.requestID) ||
               CodexRolloutTail.isAsyncInputRequest(previous.requestID) {
                checkpoints.removeValue(forKey: id)
                labels.removeValue(forKey: id)
                return nil
            }
            let confirmsLiveInput = status == .waiting && observation.requestID != nil
                && (observation.hostID != nil || CodexRolloutTail.isAsyncInputRequest(observation.requestID))
            let clarifiesUnreadCompletion = (isFinalQuestion || confirmsLiveInput)
                && previous.status == .completed && previous.notificationID != nil
            if sameTurn, (previous.status == .completed || previous.status == .failed), !clarifiesUnreadCompletion {
                return nil
            }
            if sameTurn, status == .completed, CodexFollowUpQuestion.isRequestID(previous.requestID) {
                return nil
            }
        }

        if status == .unknown, var previous {
            // A missing projection is an observation made now, rather than the turn’s event time.
            // Keep the last event watermark so a delayed terminal projection can still be applied.
            previous.markUnknown(at: now)
            // Keep the request/read identity for a temporary source gap, but hide
            // its notification until this exact request is verified again.
            checkpoints[id] = previous
            return nil
        }
        if status == .interrupted {
            checkpoints.removeValue(forKey: id)
            labels.removeValue(forKey: id)
            return nil
        }

        if var previous, sameTurn, previous.requestID == observation.requestID,
           previous.status == status || (previous.status == .unknown && status == .waiting) {
            previous.status = status
            previous.observedAt = observation.updatedAt
            previous.missingSince = nil
            checkpoints[id] = previous
            return nil
        }

        let notification = status.canNotify ? UUID() : nil
        checkpoints[id] = Checkpoint(
            turnID: observation.turnID,
            requestID: observation.requestID,
            status: status,
            observedAt: observation.updatedAt,
            changedAt: observation.updatedAt,
            highlightStartedAt: now,
            notificationID: notification,
            hostID: observation.hostID,
            threadID: observation.hostID == nil ? nil : observation.threadID
        )
        return notification
    }
}
