import Foundation
import Darwin

final class CodexRolloutTail {
    struct Start {
        let turnID: String
        let date: Date
        var ended = false
        var completedAt: Date? = nil
    }

    struct InputActivity {
        let requestID: String?
        let changedAt: Date
    }

    struct AsyncWait {
        let turnID: String
        let requestID: String
        let changedAt: Date
    }

    private struct AsyncRequest {
        let turnID: String
        let questionCount: Int
        var acceptedAt: Date?
        var observed = false
        var answeredQuestions: Set<Int> = []
    }

    private struct AsyncResolution {
        let turnID: String
        let date: Date
    }

    private struct AsyncAcceptance: Decodable {
        let accepted: Bool
    }

    private struct FileID: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private struct Cursor {
        let path: String
        let file: FileID
        var offset: UInt64
        var anchor = Data()
        var partial = Data()
        var discardingPartial = false
        var start: Start?
        var rootCompletion: Start?
        var endedTurnID: String?
        var inputTurnID: String?
        var inputRequests: [String: Date] = [:]
        var resolvedInputRequests: Set<String> = []
        var inputChangedAt: Date?
        var finalTextRequiresReply = false
        var completedFollowUp: (turnID: String, date: Date)?
        var asyncRequests: [String: AsyncRequest] = [:]
        var resolvedAsyncRequests: [String: AsyncResolution] = [:]
        var asyncChangedAt: Date?
    }

    private let sessionsPath: String
    private var cursors: [String: Cursor] = [:]
    private static let readLimit = 256 * 1024
    private static let asyncInputName = "request_user_input_async"
    private static let asyncRequestPrefix = "async-input:"
    private static let replyStart = "<send_user_message_question_reply>"
    private static let replyEnd = "</send_user_message_question_reply>"
    private let timestamp = ISO8601DateFormatter()
    private static let eventMarkers = [
        "task_started", "task_complete", "turn_aborted", "request_user_input",
        "verified_answer", "function_call_output", "final_answer", asyncInputName,
    ].map {
        Data(("\"" + $0 + "\"").utf8)
    } + [Data(replyStart.utf8)]

    init(sessionsDirectory: URL) {
        sessionsPath = sessionsDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func keepThreads(_ threadIDs: Set<String>) {
        cursors = cursors.filter { threadIDs.contains($0.key) }
    }

    func verifiedSession(for threadID: String) -> Bool {
        cursors[threadID] != nil
    }

    static func isAsyncInputRequest(_ requestID: String?) -> Bool {
        requestID?.hasPrefix(asyncRequestPrefix) == true
    }

    func asyncWait(threadID: String, since: Date, now: Date, expectedRequestID: String?) -> AsyncWait? {
        guard var cursor = cursors[threadID] else { return nil }
        for (callID, var request) in cursor.asyncRequests {
            guard let acceptedAt = request.acceptedAt, acceptedAt <= now,
                  request.observed || acceptedAt >= since || expectedRequestID == Self.asyncRequestPrefix + callID
            else { continue }
            request.observed = true
            cursor.asyncRequests[callID] = request
        }
        cursors[threadID] = cursor
        let latest = cursor.asyncRequests.filter { $0.value.observed && ($0.value.acceptedAt ?? .distantFuture) <= now }
            .max { lhs, rhs in
                if lhs.value.acceptedAt == rhs.value.acceptedAt { return lhs.key < rhs.key }
                return (lhs.value.acceptedAt ?? .distantPast) < (rhs.value.acceptedAt ?? .distantPast)
            }
        guard let latest, let changedAt = cursor.asyncChangedAt else { return nil }
        return AsyncWait(turnID: latest.value.turnID, requestID: Self.asyncRequestPrefix + latest.key, changedAt: changedAt)
    }

    func asyncResolvedAt(threadID: String, turnID: String, now: Date, expectedRequestID: String? = nil) -> Date? {
        guard let cursor = cursors[threadID] else { return nil }
        if Self.isAsyncInputRequest(expectedRequestID), let expectedRequestID {
            let callID = String(expectedRequestID.dropFirst(Self.asyncRequestPrefix.count))
            guard let resolved = cursor.resolvedAsyncRequests[callID], resolved.turnID == turnID,
                  resolved.date <= now else { return nil }
            return resolved.date
        }
        return cursor.resolvedAsyncRequests.values.filter { $0.turnID == turnID && $0.date <= now }.map(\.date).max()
    }

    func completedFollowUpDate(threadID: String, turnID: String) -> Date? {
        guard let followUp = cursors[threadID]?.completedFollowUp, followUp.turnID == turnID else { return nil }
        return followUp.date
    }

    func inputActivity(
        threadID: String, turnID: String, turnStartedAt: Date, desktopStartedAt: Date?, now: Date,
        expectedRequestID: String?
    ) -> InputActivity? {
        guard let cursor = cursors[threadID],
              cursor.inputTurnID == nil || cursor.inputTurnID == turnID else { return nil }
        let since = max(turnStartedAt, desktopStartedAt ?? .distantPast)
        guard let changedAt = cursor.inputChangedAt, changedAt >= since, changedAt <= now else { return nil }
        let waiting = cursor.inputRequests.filter {
            $0.value >= since && now.timeIntervalSince($0.value) >= 0.5
        }.max { $0.value < $1.value }
        if let expectedRequestID, waiting == nil, cursor.endedTurnID != turnID,
           !cursor.resolvedInputRequests.contains(expectedRequestID) { return nil }
        return InputActivity(
            requestID: cursor.endedTurnID == turnID ? nil : waiting?.key,
            changedAt: changedAt
        )
    }

    func latestStart(
        threadID: String, rolloutPath: String, trackedTurnID: String? = nil, expectedAsyncRequestID: String? = nil
    ) -> Start? {
        guard let fileURL = sessionURL(for: rolloutPath),
              let handle = try? FileHandle(forReadingFrom: fileURL) else {
            cursors.removeValue(forKey: threadID)
            return nil
        }
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(handle.fileDescriptor, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG, attributes.st_size >= 0 else {
            cursors.removeValue(forKey: threadID)
            return nil
        }
        let fileID = FileID(device: attributes.st_dev, inode: attributes.st_ino)
        let fileSize = UInt64(attributes.st_size)

        do {
            var cursor: Cursor
            let newCursor: Bool
            if let saved = cursors[threadID], saved.path == fileURL.path, saved.file == fileID, saved.offset <= fileSize,
               try matchesAnchor(saved, handle: handle) {
                cursor = saved
                newCursor = false
            } else {
                cursors.removeValue(forKey: threadID)
                let prefix = try handle.read(upToCount: Self.readLimit) ?? Data()
                guard let end = prefix.firstIndex(of: 10),
                      let metadata = Self.object(prefix[..<end]),
                      metadata["type"] as? String == "session_meta",
                      let payload = metadata["payload"] as? [String: Any],
                      payload["id"] as? String == threadID else { return nil }
                cursor = Cursor(path: fileURL.path, file: fileID, offset: 0)
                newCursor = true
            }

            if fileSize - cursor.offset > UInt64(Self.readLimit), cursor.inputRequests.isEmpty,
               cursor.asyncRequests.isEmpty, cursor.completedFollowUp == nil {
                cursor.offset = fileSize - UInt64(Self.readLimit)
                cursor.anchor.removeAll()
                cursor.partial.removeAll()
                cursor.discardingPartial = true
                cursor.inputTurnID = nil
                cursor.endedTurnID = nil
                cursor.rootCompletion = nil
                cursor.resolvedInputRequests.removeAll()
                cursor.inputChangedAt = nil
                cursor.finalTextRequiresReply = false
                cursor.resolvedAsyncRequests.removeAll()
                cursor.asyncChangedAt = nil
            }
            if cursor.offset < fileSize {
                try handle.seek(toOffset: cursor.offset)
                let readCount = Int(min(UInt64(Self.readLimit), fileSize - cursor.offset))
                let appended = try handle.read(upToCount: readCount) ?? Data()
                cursor.offset += UInt64(appended.count)
                cursor.anchor = Data((cursor.anchor + appended).suffix(96))
                consume(appended, into: &cursor)
            }
            if newCursor, fileSize > UInt64(Self.readLimit), let expectedAsyncRequestID,
               Self.isAsyncInputRequest(expectedAsyncRequestID) {
                let callID = String(expectedAsyncRequestID.dropFirst(Self.asyncRequestPrefix.count))
                if !callID.isEmpty, cursor.asyncRequests[callID] == nil, cursor.resolvedAsyncRequests[callID] == nil {
                    try restoreAsyncRequest(callID, handle: handle, fileSize: fileSize, into: &cursor)
                }
            }
            cursors[threadID] = cursor
            if let completion = cursor.rootCompletion, completion.turnID == trackedTurnID,
               (cursor.start?.date ?? .distantPast) <= completion.date {
                return completion
            }
            return cursor.start
        } catch {
            cursors.removeValue(forKey: threadID)
            return nil
        }
    }

    private func matchesAnchor(_ cursor: Cursor, handle: FileHandle) throws -> Bool {
        guard !cursor.anchor.isEmpty else { return true }
        try handle.seek(toOffset: cursor.offset - UInt64(cursor.anchor.count))
        return try handle.read(upToCount: cursor.anchor.count) == cursor.anchor
    }

    private func restoreAsyncRequest(_ callID: String, handle: FileHandle, fileSize: UInt64, into cursor: inout Cursor) throws {
        // A saved request can predate the tail window. Recheck only its own events once after opening the file.
        var recovery = Cursor(path: cursor.path, file: cursor.file, offset: 0)
        let filter = (id: callID, marker: Data(callID.utf8))
        try handle.seek(toOffset: 0)
        while recovery.offset < fileSize {
            let count = Int(min(UInt64(Self.readLimit), fileSize - recovery.offset))
            guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
            recovery.offset += UInt64(chunk.count)
            consume(chunk, into: &recovery, onlyAsyncCall: filter)
        }
        cursor.asyncRequests[callID] = recovery.asyncRequests[callID]
        cursor.resolvedAsyncRequests[callID] = recovery.resolvedAsyncRequests[callID]
        if let changedAt = recovery.asyncChangedAt { cursor.asyncChangedAt = max(cursor.asyncChangedAt ?? .distantPast, changedAt) }
    }

    private func sessionURL(for path: String) -> URL? {
        guard path.hasPrefix("/"), path.hasSuffix(".jsonl") else { return nil }
        let location = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard location.path.hasPrefix(sessionsPath + "/"), location.pathExtension == "jsonl" else { return nil }
        return location
    }

    private func consume(_ appended: Data, into cursor: inout Cursor, onlyAsyncCall: (id: String, marker: Data)? = nil) {
        cursor.partial.append(appended)
        var beginning = cursor.partial.startIndex
        while let end = cursor.partial[beginning...].firstIndex(of: 10) {
            if !cursor.discardingPartial {
                let line = cursor.partial[beginning..<end]
                if let onlyAsyncCall {
                    if line.range(of: onlyAsyncCall.marker) != nil {
                        applyEvent(line, to: &cursor, onlyAsyncCall: onlyAsyncCall.id)
                    }
                } else {
                    applyEvent(line, to: &cursor)
                }
            }
            cursor.discardingPartial = false
            beginning = end + 1
        }
        cursor.partial = Data(cursor.partial[beginning...])
        if cursor.partial.count > Self.readLimit {
            cursor.partial.removeAll()
            cursor.discardingPartial = true
        }
    }

    private func applyEvent(_ line: Data, to cursor: inout Cursor, onlyAsyncCall: String? = nil) {
        guard Self.eventMarkers.contains(where: { line.range(of: $0) != nil }),
              let event = Self.object(line),
              let type = event["type"] as? String,
              let payload = event["payload"] as? [String: Any],
              let kind = payload["type"] as? String else { return }

        if type == "response_item" {
            applyAsyncEvent(kind, payload: payload, event: event, to: &cursor, onlyAsyncCall: onlyAsyncCall)
        }
        if onlyAsyncCall != nil { return }

        // Some rollouts also carry the final answer as a message without a turn ID.
        // Only use this fallback when this cursor saw the matching turn start.
        if payload["phase"] as? String == "final_answer",
           let activeTurnID = cursor.inputTurnID, cursor.endedTurnID == nil,
           payload["turn_id"] == nil || payload["turn_id"] as? String == activeTurnID {
            if type == "event_msg", kind == "agent_message", let message = payload["message"] as? String {
                cursor.finalTextRequiresReply = CodexFollowUpQuestion.requiresReply(message)
            } else if type == "response_item", kind == "message", payload["role"] as? String == "assistant",
                      let content = payload["content"] as? [[String: Any]] {
                let message = content.compactMap {
                    $0["type"] as? String == "output_text" ? $0["text"] as? String : nil
                }.joined(separator: "\n")
                cursor.finalTextRequiresReply = CodexFollowUpQuestion.requiresReply(message)
            }
        }

        if type == "event_msg", let turnID = payload["turn_id"] as? String, !turnID.isEmpty {
            switch kind {
            case "task_started":
                guard let seconds = payload["started_at"] as? Double, seconds.isFinite, seconds > 0 else { return }
                cursor.start = Start(turnID: turnID, date: Date(timeIntervalSince1970: seconds))
                cursor.rootCompletion = nil
                cursor.endedTurnID = nil
                cursor.inputTurnID = turnID
                cursor.inputRequests.removeAll()
                cursor.resolvedInputRequests.removeAll()
                cursor.inputChangedAt = nil
                cursor.finalTextRequiresReply = false
                cursor.completedFollowUp = nil
            case "task_complete", "turn_aborted":
                if cursor.start?.turnID == turnID { cursor.start?.ended = true }
                guard cursor.inputTurnID == nil || cursor.inputTurnID == turnID else { return }
                cursor.endedTurnID = turnID
                cursor.inputRequests.removeAll()
                let eventTimestamp = eventDate(event)
                if cursor.inputChangedAt != nil, let eventTimestamp { cursor.inputChangedAt = eventTimestamp }
                cursor.completedFollowUp = nil
                let completedAt = (payload["completed_at"] as? Double).flatMap {
                    $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil
                }
                if kind == "task_complete", let date = completedAt ?? eventTimestamp,
                   payload["error"] == nil || payload["error"] is NSNull,
                   payload["root_turn_id"] == nil || payload["root_turn_id"] as? String == turnID {
                    // The root terminal record carries its start time, even when the bounded tail misses the start line.
                    if payload["root_turn_id"] as? String == turnID, let completedAt,
                       let seconds = payload["started_at"] as? Double, seconds.isFinite, seconds > 0 {
                        let startedAt = Date(timeIntervalSince1970: seconds)
                        if startedAt <= completedAt, cursor.start?.turnID != turnID || cursor.start?.date == startedAt {
                            cursor.rootCompletion = Start(turnID: turnID, date: startedAt, ended: true, completedAt: completedAt)
                        }
                    }
                    let needsReply = (payload["last_agent_message"] as? String).map(CodexFollowUpQuestion.requiresReply)
                        ?? cursor.finalTextRequiresReply
                    if needsReply { cursor.completedFollowUp = (turnID, date) }
                }
                cursor.finalTextRequiresReply = false
            default: break
            }
            return
        }

        guard let callID = payload["call_id"] as? String, !callID.isEmpty else { return }
        if type == "response_item", kind == "function_call", payload["name"] as? String == "request_user_input" {
            guard let date = eventDate(event), cursor.inputRequests[callID] == nil else { return }
            cursor.inputRequests[callID] = date
            cursor.inputChangedAt = date
        } else if (type == "response_item" && kind == "function_call_output")
                    || (type == "retained_context" && kind == "verified_answer") {
            guard cursor.inputRequests[callID] != nil, let date = eventDate(event) else { return }
            if let turnID = payload["turn_id"] as? String, let scoped = cursor.inputTurnID, turnID != scoped {
                return
            }
            cursor.inputRequests.removeValue(forKey: callID)
            cursor.resolvedInputRequests.insert(callID)
            cursor.inputChangedAt = date
        }
    }

    private func applyAsyncEvent(
        _ kind: String, payload: [String: Any], event: [String: Any], to cursor: inout Cursor, onlyAsyncCall: String?
    ) {
        if kind == "message", payload["role"] as? String == "user", !cursor.asyncRequests.isEmpty,
           let content = payload["content"] as? [[String: Any]], let date = eventDate(event) {
            for item in content where item["type"] as? String == "input_text" {
                guard let reply = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      reply.hasPrefix(Self.replyStart), reply.hasSuffix(Self.replyEnd),
                      let answers = try? JSONSerialization.jsonObject(with: Data(
                          reply.dropFirst(Self.replyStart.count).dropLast(Self.replyEnd.count).utf8
                      )) as? [[String: Any]] else { continue }
                for answer in answers {
                    guard answer["answer"] != nil, let id = answer["questionItemId"] as? String,
                          let parts = try? JSONSerialization.jsonObject(with: Data(id.utf8)) as? [Any], parts.count == 3,
                          parts[0] as? String == Self.asyncInputName, let callID = parts[1] as? String,
                          onlyAsyncCall == nil || callID == onlyAsyncCall,
                          let index = parts[2] as? Int, var request = cursor.asyncRequests[callID],
                          let acceptedAt = request.acceptedAt, date >= acceptedAt,
                          (0..<request.questionCount).contains(index) else { continue }
                    request.answeredQuestions.insert(index)
                    if request.answeredQuestions.count == request.questionCount {
                        resolveAsyncRequest(callID, request: request, at: date, in: &cursor)
                    } else {
                        cursor.asyncRequests[callID] = request
                    }
                }
            }
            return
        }

        guard let callID = payload["call_id"] as? String, !callID.isEmpty,
              onlyAsyncCall == nil || callID == onlyAsyncCall else { return }
        if kind == "function_call", payload["name"] as? String == Self.asyncInputName,
           let metadata = payload["internal_chat_message_metadata_passthrough"] as? [String: Any],
           let turnID = metadata["turn_id"] as? String, !turnID.isEmpty,
           let arguments = payload["arguments"] as? String, let parsed = Self.object(Data(arguments.utf8)),
           let questions = parsed["questions"] as? [[String: Any]], !questions.isEmpty,
           cursor.asyncRequests[callID] == nil, cursor.resolvedAsyncRequests[callID] == nil {
            cursor.asyncRequests[callID] = AsyncRequest(turnID: turnID, questionCount: questions.count)
        } else if kind == "function_call_output", var request = cursor.asyncRequests[callID],
                  let output = payload["output"] as? String,
                  let result = try? JSONDecoder().decode(AsyncAcceptance.self, from: Data(output.utf8)),
                  let date = eventDate(event) {
            if result.accepted {
                guard request.acceptedAt == nil else { return }
                request.acceptedAt = date
                cursor.asyncRequests[callID] = request
                cursor.asyncChangedAt = max(cursor.asyncChangedAt ?? .distantPast, date)
            } else if request.acceptedAt != nil {
                resolveAsyncRequest(callID, request: request, at: date, in: &cursor)
            } else {
                cursor.asyncRequests.removeValue(forKey: callID)
            }
        }
    }

    private func resolveAsyncRequest(_ callID: String, request: AsyncRequest, at date: Date, in cursor: inout Cursor) {
        cursor.asyncRequests.removeValue(forKey: callID)
        cursor.resolvedAsyncRequests[callID] = AsyncResolution(turnID: request.turnID, date: date)
        cursor.asyncChangedAt = max(cursor.asyncChangedAt ?? .distantPast, date)
    }

    private func eventDate(_ event: [String: Any]) -> Date? {
        (event["timestamp"] as? String).flatMap(timestamp.date(from:))
    }

    private static func object(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }
}
