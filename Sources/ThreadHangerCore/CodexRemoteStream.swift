import CoreFoundation
import Foundation

public struct CodexRemoteTurn: Equatable, Sendable {
    public let turnID: String
    public let status: ThreadStatus
    public let happenedAt: Date
    public let requestID: String?
    public let asksForReply: Bool
    /// Local time when this feed first verified the turn active on the current subscription.
    public let observedActiveAt: Date?
    /// A completed turn carried a native input, possibly already answered.
    public let hadPendingInputAfterCompletion: Bool
    fileprivate let waitingFlags: String
    fileprivate let exactRequestID: String?
    fileprivate let previousFallbackIDs: [String: String]
    fileprivate let finalAnswerResolved: Bool
}

public struct CodexRemoteThread: Identifiable, Equatable, Sendable {
    public let hostID: String
    public let threadID: String
    public let title: String
    public let cwd: String
    public let updatedAt: Date
    /// Oldest first, ordered by the turn start rather than its completion time.
    public let turns: [CodexRemoteTurn]

    public var id: String { "\(hostID)/\(threadID)" }
    public var isActive: Bool { turns.last?.status.isActive == true }

    public func turnsForObservation(trackedTurnID: String?) -> [CodexRemoteTurn] {
        guard let latest = turns.last else { return [] }
        guard let trackedTurnID, trackedTurnID != latest.turnID,
              let tracked = turns.last(where: { $0.turnID == trackedTurnID }) else { return [latest] }
        // A reply in a later turn may have answered only part of the picker.
        if tracked.status == .waiting { return [tracked] }
        return [tracked, latest]
    }
}

struct CodexRemoteStream {
    private struct Address: Hashable {
        let host: String
        let thread: String
    }

    struct Following {
        let host: String
        let thread: String
        let peer: String
        let following: Bool

        func message(clientID: String) -> [String: Any] {
            ["type": "broadcast", "method": "thread-stream-following-changed", "version": 1,
             "sourceClientId": clientID, "targetClientIds": [peer],
             "params": ["hostId": host, "conversationId": thread, "following": following]]
        }
    }

    private struct Subscription {
        let peer: String
        var revision: Int?
        var projection: [String: Any] = [:]
        var thread: CodexRemoteThread?
        var requestedSnapshot = false
        var deferredCompletion: (previous: CodexRemoteThread, deadline: DispatchTime)?

        mutating func clearResolvedCompletion(at now: DispatchTime) {
            guard let deferred = deferredCompletion else { return }
            if let latest = thread?.turns.last, latest.turnID == deferred.previous.turns.last?.turnID,
               latest.status == .completed, !latest.finalAnswerResolved, now < deferred.deadline {
                return
            }
            deferredCompletion = nil
        }
    }

    private var subscriptions: [Address: Subscription] = [:]
    var threads: [CodexRemoteThread] { threads(at: .now()) }
    var nextCompletionDeadline: DispatchTime? {
        subscriptions.values.compactMap { $0.deferredCompletion?.deadline }.min()
    }

    func threads(at now: DispatchTime) -> [CodexRemoteThread] {
        subscriptions.values.compactMap { subscription in
            if let deferred = subscription.deferredCompletion, now < deferred.deadline {
                return deferred.previous
            }
            return subscription.thread
        }
    }

    mutating func expireCompletions(at now: DispatchTime = .now()) {
        for address in subscriptions.keys {
            if let deferred = subscriptions[address]?.deferredCompletion, now >= deferred.deadline {
                subscriptions[address]?.deferredCompletion = nil
            }
        }
    }

    mutating func consume(_ message: [String: Any], clientID: String, now: DispatchTime = .now()) -> [Following] {
        guard message["type"] as? String == "broadcast",
              let method = message["method"] as? String,
              let params = message["params"] as? [String: Any] else { return [] }
        if let targets = message["targetClientIds"] {
            guard let targets = targets as? [String], targets.contains(clientID) else { return [] }
        }

        if method == "client-status-changed", params["status"] as? String == "disconnected",
           let peer = params["clientId"] as? String {
            return removeFollowing { $0 == peer }
        }

        guard let source = message["sourceClientId"] as? String, !source.isEmpty,
              source.utf8.count <= 256, source != clientID,
              let host = params["hostId"] as? String, Self.isRemoteHost(host),
              let thread = params["conversationId"] as? String, UUID(uuidString: thread) != nil else { return [] }
        let address = Address(host: host, thread: thread)
        let subscribe = Following(host: host, thread: thread, peer: source, following: true)

        switch (method, message["version"] as? Int) {
        case ("thread-stream-following-changed", 1):
            guard let following = params["following"] as? Bool else { return [] }
            if following, subscriptions[address] == nil, subscriptions.count < 64 {
                subscriptions[address] = Subscription(peer: source)
                return [subscribe]
            }
            if !following, subscriptions[address]?.peer == source {
                subscriptions.removeValue(forKey: address)
                return [Following(host: host, thread: thread, peer: source, following: false)]
            }
        case ("thread-stream-state-changed", 13):
            guard let targets = message["targetClientIds"] as? [String], targets.contains(clientID),
                  var subscription = subscriptions[address], subscription.peer == source,
                  let change = params["change"] as? [String: Any],
                  let revision = change["revision"] as? Int, revision >= 0 else { return [] }

            switch change["type"] as? String {
            case "snapshot":
                guard subscription.revision.map({ revision >= $0 }) ?? true,
                      let state = change["conversationState"] as? [String: Any],
                      state["id"] as? String == thread, state["hostId"] as? String == host,
                      let projection = Self.schema.project(state) as? [String: Any] else { return [] }
                subscription.revision = revision
                subscription.projection = projection
                subscription.thread = Self.thread(address, state: projection, previous: subscription.thread)
                subscription.requestedSnapshot = false
                subscription.clearResolvedCompletion(at: now)
            case "patches":
                if let current = subscription.revision, revision <= current { return [] }
                if let current = subscription.revision, change["baseRevision"] as? Int == current,
                   let patches = change["patches"] as? [[String: Any]],
                   let (projection, changed) = Self.apply(patches, to: subscription.projection) {
                    subscription.revision = revision
                    subscription.projection = projection
                    if changed {
                        let previous = subscription.thread
                        subscription.thread = Self.thread(address, state: projection, previous: subscription.thread)
                        if let latest = subscription.thread?.turns.last, latest.status == .completed,
                           !latest.finalAnswerResolved, let previous, let active = previous.turns.last,
                           latest.turnID == active.turnID, active.status.isActive {
                            // The terminal patch can precede the final text. Ask the owner once and give it
                            // a short window to send a fresh snapshot or the remaining item patch.
                            subscription.deferredCompletion = (previous, now + .milliseconds(500))
                            subscriptions[address] = subscription
                            return [subscribe]
                        }
                        subscription.clearResolvedCompletion(at: now)
                    }
                } else {
                    // A repeated following announcement asks the known owner for a replacement snapshot.
                    if subscription.requestedSnapshot { return [] }
                    subscription.revision = nil
                    subscription.projection = [:]
                    subscription.thread = nil
                    subscription.requestedSnapshot = true
                    subscription.deferredCompletion = nil
                    subscriptions[address] = subscription
                    return [subscribe]
                }
            default:
                return []
            }
            subscriptions[address] = subscription
        default:
            break
        }
        return []
    }

    mutating func stopFollowing() -> [Following] { removeFollowing { _ in true } }

    private mutating func removeFollowing(where matches: (String) -> Bool) -> [Following] {
        let removed = subscriptions.filter { matches($0.value.peer) }
        for address in removed.keys { subscriptions.removeValue(forKey: address) }
        return removed.map { address, value in
            Following(host: address.host, thread: address.thread, peer: value.peer, following: false)
        }
    }

    private static func isRemoteHost(_ host: String) -> Bool {
        guard host.hasPrefix("remote-control:env_"), host.utf8.count <= 128 else { return false }
        let suffix = host.utf8.dropFirst("remote-control:env_".utf8.count)
        return !suffix.isEmpty && suffix.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static let requestMethods: Set<String> = [
        "item/commandExecution/requestApproval", "item/fileChange/requestApproval",
        "item/permissions/requestApproval", "item/tool/requestUserInput", "item/tool/requestOptionPicker",
        "mcpServer/elicitation/request"
    ]

    private static let nonblockingInputPrefix = "remote-nonblocking-input:"

    static func isNonblockingInput(_ requestID: String?) -> Bool {
        requestID?.hasPrefix(nonblockingInputPrefix) == true
    }

    private struct AsyncAnswer: Hashable {
        let itemID: String
        let index: Int
    }

    private static func asyncAnswers(_ value: Any) -> [AsyncAnswer] {
        let opening = "<send_user_message_question_reply>"
        let closing = "</send_user_message_question_reply>"
        guard let text = value as? String, text.utf8.count <= 64 * 1024 else { return [] }
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard reply.hasPrefix(opening), reply.hasSuffix(closing),
              let parsed = try? JSONSerialization.jsonObject(with: Data(
                  reply.dropFirst(opening.count).dropLast(closing.count).utf8
              )) else { return [] }
        let answers = (parsed as? [[String: Any]]) ?? (parsed as? [String: Any]).map { [$0] } ?? []
        return answers.compactMap { answer in
            guard answer["answer"] is String, let id = answer["questionItemId"] as? String, id.utf8.count <= 512,
                  let parts = try? JSONSerialization.jsonObject(with: Data(id.utf8)) as? [Any], parts.count == 3,
                  parts[0] as? String == "request_user_input_async",
                  let itemID = parts[1] as? String, !itemID.isEmpty,
                  let index = parts[2] as? NSNumber, CFGetTypeID(index) != CFBooleanGetTypeID(),
                  (0..<64).contains(index.intValue), index.doubleValue == Double(index.intValue) else { return nil }
            return AsyncAnswer(itemID: itemID, index: index.intValue)
        }
    }

    private struct AsyncQuestions {
        var hadQuestions = false
        var pendingItemID: String?

        init(items: [[String: Any]], laterAnswers: inout Set<AsyncAnswer>) {
            for item in items.reversed() {
                switch item["type"] as? String {
                case "agentMessage":
                    guard let id = item["id"] as? String, !id.isEmpty,
                          let questions = item["questions"] as? [[String: Any]], !questions.isEmpty else { continue }
                    hadQuestions = true
                    if pendingItemID == nil, questions.indices.contains(where: {
                        !laterAnswers.contains(AsyncAnswer(itemID: id, index: $0))
                    }) {
                        pendingItemID = id
                    }
                case "userMessage", "steeringUserMessage":
                    let acceptedSteering = item["status"] as? String == "accepted"
                        || item["steerAcknowledged"] as? Bool == true
                    let content = item["type"] as? String == "userMessage" ? item["content"]
                        : acceptedSteering ? item["input"] : nil
                    for entry in content as? [[String: Any]] ?? [] where entry["type"] as? String == "text" {
                        laterAnswers.formUnion(entry["text"] as? [AsyncAnswer] ?? [])
                    }
                default: break
                }
            }
        }
    }

    private static func dynamicInputTool(_ value: Any) -> String? {
        guard let arguments = value as? [String: Any] else { return nil }

        func optionalText(_ value: Any?) -> Bool {
            value == nil || value is NSNull || value is String
        }

        func isOption(_ value: Any) -> Bool {
            guard let option = value as? [String: Any] else { return false }
            return option["label"] is String && optionalText(option["description"])
        }

        if arguments["question"] is String,
           let options = arguments["options"] as? [Any], options.allSatisfy(isOption),
           arguments["allowMultiple"].map({ Schema.boolean.project($0) is NSNumber }) ?? true,
           optionalText(arguments["submitLabel"]), optionalText(arguments["skipLabel"]) {
            return "request_option_picker"
        }
        if arguments.count == 1, let questions = arguments["questions"] as? [[String: Any]],
           (1...3).contains(questions.count), questions.allSatisfy({ question in
               Set(question.keys).isSubset(of: ["id", "header", "question", "options"]) &&
               question["id"] is String && question["question"] is String && optionalText(question["header"]) &&
               (question["options"] as? [Any]).map { $0.count >= 2 && $0.allSatisfy(isOption) } == true
           }) {
            return "request_onboarding_input"
        }
        return nil
    }

    private static func thread(
        _ address: Address, state: [String: Any], previous: CodexRemoteThread?
    ) -> CodexRemoteThread {
        let createdAt = date(state["createdAt"]) ?? .distantPast
        let updatedAt = date(state["updatedAt"]) ?? createdAt
        let recencyAt = date(state["recencyAt"]) ?? updatedAt
        let history = state["turnHistory"] as? [String: Any]
        let canonical = history?["history"] as? [String: Any]
        let entities = canonical?["entitiesByKey"] as? [String: [String: Any]] ?? [:]
        let turnKeys = entities.keys.filter { $0.hasPrefix("turn:") }.sorted()
        let tailKeys = entities.keys.filter { $0.hasPrefix("tail:") }.sorted()
        var byID: [String: [String: Any]] = [:]
        func add(_ values: [String: Any]) {
            guard let id = (values["turnId"] ?? values["id"]) as? String, !id.isEmpty else { return }
            if let root = values["rootTurnId"] as? String, !root.isEmpty, root != id { return }
            byID[id, default: [:]].merge(values) { old, new in new is NSNull ? old : new }
        }
        for values in state["turns"] as? [[String: Any]] ?? [] { add(values) }
        if history?["kind"] as? String == "canonical" {
            for key in turnKeys + tailKeys {
                if let values = entities[key] { add(values) }
            }
        }
        let startedTurns = byID.compactMap { id, values -> (String, [String: Any], Date)? in
            guard let start = date(values["turnStartedAtMs"]) else { return nil }
            return (id, values, start)
        }.sorted { $0.2 == $1.2 ? $0.0 < $1.0 : $0.2 < $1.2 }.suffix(128)

        // Codex places asynchronous pickers in the transcript, even when the server request list is empty.
        // A later accepted user message can answer one or more questions by item ID and index.
        var laterAnswers = Set<AsyncAnswer>()
        var asyncQuestions: [String: AsyncQuestions] = [:]
        for (id, values, _) in startedTurns.reversed() {
            let questions = AsyncQuestions(items: values["items"] as? [[String: Any]] ?? [], laterAnswers: &laterAnswers)
            if questions.hadQuestions { asyncQuestions[id] = questions }
        }

        let latest = startedTurns.last?.0
        let runtime = state["threadRuntimeStatus"] as? [String: Any]
        let runtimeType = runtime?["type"] as? String
        let flags = Set(runtime?["activeFlags"] as? [String] ?? [])
            .intersection(["waitingOnApproval", "waitingOnUserInput"]).sorted().joined(separator: "+")
        let requests = state["requests"] as? [[String: Any]] ?? []
        let previousTurns = Dictionary(uniqueKeysWithValues: (previous?.turns ?? []).map { ($0.turnID, $0) })
        let now = Date()
        let turns = startedTurns.map { id, values, start -> CodexRemoteTurn in
            let status: ThreadStatus
            let last = previousTurns[id]
            var requestID: String?
            var exactRequestID: String?
            var previousFallbackIDs = last?.previousFallbackIDs ?? [:]
            let turnStatus = values["status"] as? String
            let questions = asyncQuestions[id]
            if id == latest, turnStatus == "inProgress" || turnStatus == "completed" {
                exactRequestID = requests.reversed().lazy.compactMap { request -> String? in
                    guard request["completed"] as? Bool != true,
                          let method = request["method"] as? String,
                          let params = request["params"] as? [String: Any] else { return nil }
                    let tool = params["tool"] as? String
                    let dynamicInput = method == "item/tool/call" && tool != nil && tool == params["arguments"] as? String
                    guard requestMethods.contains(method) || dynamicInput else { return nil }
                    if let requestHost = params["hostId"] as? String, requestHost != address.host {
                        return nil
                    }
                    if let requestThread = params["threadId"] as? String, requestThread != address.thread {
                        return nil
                    }
                    let matchesThread = params["threadId"] as? String == address.thread
                    let elicitation = method == "mcpServer/elicitation/request"
                    guard !elicitation || matchesThread else { return nil }
                    let requestTurn = (params["turnId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    if turnStatus == "completed" {
                        guard method == "item/tool/requestUserInput", params["isBlocking"] as? Bool == false,
                              matchesThread, requestTurn == id else { return nil }
                    }
                    guard requestTurn == id || (requestTurn == nil && matchesThread && !dynamicInput &&
                          (elicitation || (runtimeType == "active" && !flags.isEmpty))) else { return nil }
                    let key = (request["id"] as? String) ?? (request["id"] as? NSNumber)?.stringValue
                    guard let key, !key.isEmpty else { return nil }
                    if method == "item/tool/requestUserInput", params["isBlocking"] as? Bool == false {
                        return nonblockingInputPrefix + key
                    }
                    return key
                }.first
            }
            // Match the Desktop renderer, which identifies the async picker by agentMessage.questions.
            if exactRequestID == nil, let itemID = questions?.pendingItemID,
               turnStatus == "inProgress" || turnStatus == "completed" {
                exactRequestID = nonblockingInputPrefix + "async:" + itemID
            }
            switch turnStatus {
            case "completed" where exactRequestID != nil:
                requestID = exactRequestID
                status = .waiting
            case "inProgress" where (id == latest && runtimeType == "active") || exactRequestID != nil:
                if !flags.isEmpty, let last, last.status == .waiting,
                   last.waitingFlags == flags || last.waitingFlags.isEmpty,
                   exactRequestID == nil || last.exactRequestID == nil || exactRequestID == last.exactRequestID {
                    requestID = last.requestID
                    exactRequestID = exactRequestID ?? last.exactRequestID
                } else if let exactRequestID {
                    requestID = exactRequestID
                } else if !flags.isEmpty {
                    let milliseconds = Int64(max(start, updatedAt).timeIntervalSince1970 * 1000)
                    let base = "runtime:\(flags):\(milliseconds)"
                    // The timestamp makes an unchanged initial snapshot deterministic across reconnects.
                    // Distinguish a later repeat if the desktop left its activity timestamp unchanged.
                    let previousFallback = previousFallbackIDs[flags]
                    let repeated = previousFallback == base || previousFallback?.hasPrefix(base + ":") == true
                    let fallback = repeated ? "\(base):\(UUID().uuidString)" : base
                    previousFallbackIDs[flags] = fallback
                    requestID = fallback
                }
                status = requestID == nil ? .running : .waiting
            case "completed": status = .completed
            case "failed": status = .failed
            case "interrupted": status = .interrupted
            default: status = .unknown
            }
            var happenedAt = start
            if status == .waiting && turnStatus != "completed" {
                happenedAt = max(start, updatedAt)
            } else if turnStatus == "completed" || (!status.isActive && status != .unknown) {
                if let duration = values["durationMs"] as? Double, duration.isFinite, duration >= 0 {
                    happenedAt = start.addingTimeInterval(duration / 1000)
                } else if id == latest {
                    happenedAt = max(start, updatedAt)
                }
            }
            if let last {
                happenedAt = max(last.happenedAt, happenedAt)
            }
            let finalAnswer = (values["items"] as? [[String: Any]])?.last {
                $0["type"] as? String == "agentMessage" && $0["phase"] as? String == "final_answer"
            }?["text"] as? Bool
            let hadPendingInputAfterCompletion = turnStatus == "completed" &&
                (exactRequestID != nil || questions?.hadQuestions == true || last?.hadPendingInputAfterCompletion == true)
            return CodexRemoteTurn(
                turnID: id, status: status, happenedAt: happenedAt, requestID: requestID,
                asksForReply: id == latest && status == .completed && finalAnswer == true && !hadPendingInputAfterCompletion,
                observedActiveAt: last?.observedActiveAt ?? (status.isActive ? now : nil),
                hadPendingInputAfterCompletion: hadPendingInputAfterCompletion,
                waitingFlags: status == .waiting ? flags : "", exactRequestID: exactRequestID,
                previousFallbackIDs: previousFallbackIDs, finalAnswerResolved: finalAnswer != nil || hadPendingInputAfterCompletion
            )
        }
        let title = state["title"] as? String
        return CodexRemoteThread(
            hostID: address.host, threadID: address.thread, title: title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled thread",
            cwd: state["cwd"] as? String ?? "", updatedAt: max(updatedAt, recencyAt), turns: turns
        )
    }

    private static func date(_ value: Any?) -> Date? {
        guard let ms = value as? Double, ms.isFinite, ms > 0, ms < 1e14 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    // Keep only values used by the projection, including inside an Immer patch replacing an entire subtree.
    private indirect enum Schema {
        case text(Int)
        case number
        case boolean
        case requestID
        case nativeInputArguments
        case assistantReply
        case asyncReply
        case object([String: Schema])
        case entities(Schema)
        case array(Schema, Int)

        func child(_ key: String) -> Schema? {
            switch self {
            case .object(let fields): return fields[key]
            case .entities(let field):
                return key.utf8.count <= 256 && (key.hasPrefix("turn:") || key.hasPrefix("tail:")) ? field : nil
            case .array(let field, _):
                guard let index = Int(key), index >= 0 else { return nil }
                return field
            default: return nil
            }
        }

        func project(_ value: Any) -> Any {
            switch self {
            case .text(let limit):
                guard let string = value as? String, string.utf8.count <= limit else { return NSNull() }
                return string
            case .number:
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite else { return NSNull() }
                return number
            case .boolean:
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID()
                else { return NSNull() }
                return number
            case .requestID:
                if let text = value as? String { return Schema.text(256).project(text) }
                return Schema.number.project(value)
            case .nativeInputArguments:
                return CodexRemoteStream.dynamicInputTool(value).map { $0 as Any } ?? NSNull()
            case .assistantReply:
                guard let text = value as? String, !text.isEmpty else { return NSNull() }
                return CodexFollowUpQuestion.requiresReply(text)
            case .asyncReply: return CodexRemoteStream.asyncAnswers(value)
            case .object, .entities:
                guard let object = value as? [String: Any] else { return NSNull() }
                var selected: [String: Any] = [:]
                for (key, value) in object {
                    if let schema = child(key), selected.count < 4096 {
                        selected[key] = schema.project(value)
                    }
                }
                return selected
            case .array(let field, let limit):
                guard let array = value as? [Any], array.count <= limit else { return NSNull() }
                return array.map(field.project)
            }
        }
    }

    private static let replyContent = Schema.array(.object(["type": .text(64), "text": .asyncReply]), 128)

    private static let turnSchema = Schema.object([
        "id": .text(256), "turnId": .text(256), "rootTurnId": .text(256),
        "turnStartedAtMs": .number, "durationMs": .number, "status": .text(64),
        "items": .array(.object([
            "id": .text(256), "type": .text(64), "phase": .text(64), "text": .assistantReply,
            "questions": .array(.object([:]), 64),
            "content": replyContent, "input": replyContent, "status": .text(64), "steerAcknowledged": .boolean
        ]), 4096)
    ])

    private static let schema = Schema.object([
        "title": .text(4096), "cwd": .text(4096), "createdAt": .number, "updatedAt": .number, "recencyAt": .number,
        "threadRuntimeStatus": .object(["type": .text(64), "activeFlags": .array(.text(64), 32)]),
        "requests": .array(.object(["id": .requestID, "method": .text(128), "completed": .boolean,
                                     "params": .object(["turnId": .text(256), "threadId": .text(256),
                                                        "hostId": .text(128), "tool": .text(128),
                                                        "arguments": .nativeInputArguments, "isBlocking": .boolean])]), 64),
        "turns": .array(turnSchema, 4096),
        "turnHistory": .object(["kind": .text(64), "history": .object(["entitiesByKey": .entities(turnSchema)])])
    ])

    private static func apply(_ patches: [[String: Any]], to state: [String: Any]) -> ([String: Any], Bool)? {
        var next: Any = state
        var changed = false
        for patch in patches {
            guard let path = patch["path"] as? [Any], !path.isEmpty,
                  let operation = patch["op"] as? String else { return nil }
            var segments: [String] = []
            var field = schema
            for element in path {
                guard let key = (element as? String) ?? (element as? Int).map(String.init),
                      let child = field.child(key) else { break }
                segments.append(key)
                field = child
            }
            guard segments.count == path.count else { continue }
            guard ["add", "replace", "remove"].contains(operation),
                  operation == "remove" || patch["value"] != nil else { return nil }
            let value = patch["value"].map(field.project)
            guard let result = replacing(next, schema: schema, path: segments[...],
                                         operation: operation, value: value) else {
                return nil
            }
            next = result
            changed = true
        }
        guard let projected = next as? [String: Any] else { return nil }
        return (projected, changed)
    }

    private static func replacing(
        _ node: Any, schema: Schema, path: ArraySlice<String>, operation: String, value: Any?
    ) -> Any? {
        guard let key = path.first else { return value }
        guard let field = schema.child(key) else { return nil }
        if var object = node as? [String: Any] {
            if path.count == 1 {
                if operation == "remove" {
                    object.removeValue(forKey: key)
                } else {
                    guard object[key] != nil || object.count < 4096 else { return nil }
                    object[key] = value
                }
            } else {
                guard let child = object[key],
                      let result = replacing(child, schema: field, path: path.dropFirst(),
                                             operation: operation, value: value) else {
                    return nil
                }
                object[key] = result
            }
            return object
        }
        if case .array(_, let limit) = schema, var array = node as? [Any], let index = Int(key) {
            if path.count == 1, operation == "add" {
                guard let value, index <= array.count, array.count < limit else { return nil }
                array.insert(value, at: index)
            } else {
                guard array.indices.contains(index) else { return nil }
                if path.count == 1, operation == "remove" {
                    array.remove(at: index)
                } else {
                    guard let result = replacing(array[index], schema: field, path: path.dropFirst(),
                                                 operation: operation, value: value) else { return nil }
                    array[index] = result
                }
            }
            return array
        }
        return nil
    }
}
