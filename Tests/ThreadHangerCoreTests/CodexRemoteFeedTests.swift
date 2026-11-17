import Darwin
import Foundation
import XCTest
@testable import ThreadHangerCore

final class CodexRemoteFeedTests: XCTestCase {
    private let host = "remote-control:env_first"
    private let thread = "019abcdf-0000-7000-8000-000000000001"

    func testScopeAndReadOnlyFollowingLifecycle() {
        var feed = CodexRemoteStream()
        XCTAssertTrue(feed.consume(following(host: "local", source: "desktop"), clientID: "mine").isEmpty)
        XCTAssertTrue(feed.consume(following(host: host, source: "mine"), clientID: "mine").isEmpty)
        XCTAssertTrue(feed.consume(following(host: host, source: "desktop", target: "other"), clientID: "mine").isEmpty)
        XCTAssertTrue(feed.consume(state(source: "desktop", change: snapshot()), clientID: "mine").isEmpty)
        XCTAssertTrue(feed.threads.isEmpty)

        let start = feed.consume(following(host: host, source: "desktop"), clientID: "mine")
        XCTAssertEqual(start.map(\.following), [true])
        XCTAssertEqual(start.first?.peer, "desktop")
        XCTAssertTrue(feed.consume(state(source: "other", change: snapshot()), clientID: "mine").isEmpty)
        XCTAssertTrue(feed.consume(state(source: "desktop", target: "other", change: snapshot()), clientID: "mine").isEmpty)
        XCTAssertTrue(feed.threads.isEmpty)

        _ = feed.consume(state(source: "desktop", change: snapshot()), clientID: "mine")
        _ = feed.consume(following(host: "remote-control:env_second", source: "desktop"), clientID: "mine")
        _ = feed.consume(state(host: "remote-control:env_second", source: "desktop",
                               change: snapshot(host: "remote-control:env_second")), clientID: "mine")
        XCTAssertEqual(feed.threads.count, 2)
        XCTAssertEqual(Set(feed.threads.map(\.id)).count, 2)

        let end = feed.consume(following(host: host, source: "desktop", following: false), clientID: "mine")
        XCTAssertEqual(end.map(\.following), [false])
        XCTAssertEqual(feed.threads.map(\.hostID), ["remote-control:env_second"])
        XCTAssertEqual(feed.stopFollowing().map(\.following), [false])
        XCTAssertTrue(feed.threads.isEmpty)
    }

    func testCanonicalPatchesPreserveTrackedTurnsAndProjectPendingRequests() {
        var feed = CodexRemoteStream()
        _ = feed.consume(following(host: host, source: "desktop"), clientID: "mine")
        _ = feed.consume(state(source: "desktop", change: snapshot()), clientID: "mine")
        XCTAssertEqual(feed.threads.first?.turns.map(\.turnID), ["previous", "current"])
        XCTAssertEqual(feed.threads.first?.turns.map(\.status), [.completed, .running])
        XCTAssertEqual(feed.threads.first?.isActive, true)
        XCTAssertNil(feed.threads.first?.turns.first?.observedActiveAt)
        let seenActiveAt = feed.threads.first?.turns.last?.observedActiveAt
        XCTAssertNotNil(seenActiveAt)

        let request: [String: Any] = [
            "method": "item/tool/requestUserInput", "id": 42,
            "params": ["turnId": "current", "questions": ["never retained"]]
        ]
        _ = feed.consume(state(source: "desktop", change: patches(base: 4, revision: 5, [
            ["op": "add", "path": ["requests", 0] as [Any], "value": request],
            ["op": "add", "path": ["threadRuntimeStatus", "activeFlags", 0] as [Any],
             "value": "waitingOnUserInput"],
            ["op": "add", "path": ["turnHistory", "history", "entitiesByKey", "item:x"],
             "value": ["output": "never retained"]]
        ])), clientID: "mine")
        XCTAssertEqual(feed.threads.first?.turns.last?.status, .waiting)
        XCTAssertEqual(feed.threads.first?.turns.last?.requestID, "42")

        _ = feed.consume(state(source: "desktop", change: patches(base: 5, revision: 6, [
            ["op": "remove", "path": ["requests", 0] as [Any]],
            ["op": "remove", "path": ["threadRuntimeStatus", "activeFlags", 0] as [Any]],
            ["op": "replace", "path": ["turnHistory", "history", "entitiesByKey", "tail:current", "status"],
             "value": "completed"],
            ["op": "replace", "path": ["turnHistory", "history", "entitiesByKey", "tail:current", "items"],
             "value": [["type": "agentMessage", "phase": "final_answer", "text": "The task is complete."]]],
            ["op": "replace", "path": ["turnHistory", "history", "entitiesByKey", "tail:current", "durationMs"],
             "value": 3000]
        ])), clientID: "mine")
        XCTAssertEqual(feed.threads.first?.turns.map(\.status), [.completed, .completed])
        XCTAssertNil(feed.threads.first?.turns.last?.requestID)
        XCTAssertEqual(feed.threads.first?.turns.last?.observedActiveAt, seenActiveAt)
        XCTAssertEqual(feed.threads.first?.isActive, false)
    }

    func testVerifiedRuntimeWaitingFlagsKeepTheirIdentityUntilEpisodeChanges() throws {
        var feed = CodexRemoteStream()
        _ = feed.consume(following(host: host, source: "desktop"), clientID: "mine")
        _ = feed.consume(state(source: "desktop", change: snapshot()), clientID: "mine")
        func flags(_ base: Int, _ flags: [String]) -> [String: Any] {
            state(source: "desktop", change: patches(base: base, revision: base + 1, [
                ["op": "replace", "path": ["threadRuntimeStatus", "activeFlags"], "value": flags]
            ]))
        }

        _ = feed.consume(flags(4, ["waitingOnApproval"]), clientID: "mine")
        let first = try XCTUnwrap(feed.threads.first?.turns.last)
        XCTAssertEqual(first.status, .waiting)
        XCTAssertNotNil(first.requestID)
        _ = feed.consume(flags(5, ["waitingOnApproval"]), clientID: "mine")
        XCTAssertEqual(feed.threads.first?.turns.last?.requestID, first.requestID)
        _ = feed.consume(flags(6, ["waitingOnUserInput", "waitingOnApproval"]), clientID: "mine")
        XCTAssertNotEqual(feed.threads.first?.turns.last?.requestID, first.requestID)
        _ = feed.consume(flags(7, []), clientID: "mine")
        XCTAssertEqual(feed.threads.first?.turns.last?.status, .running)
        XCTAssertEqual(feed.threads.first?.turns.last?.happenedAt, first.happenedAt)
        _ = feed.consume(flags(8, ["waitingOnApproval"]), clientID: "mine")
        XCTAssertEqual(feed.threads.first?.turns.last?.status, .waiting)
        XCTAssertNotEqual(feed.threads.first?.turns.last?.requestID, first.requestID)
    }

    func testDefaultNativeInputDoesNotRequireWaitingFlagsOrBlockingExecution() {
        var feed = CodexRemoteStream()
        _ = feed.consume(following(host: host, source: "desktop"), clientID: "mine")
        _ = feed.consume(state(source: "desktop", change: snapshot()), clientID: "mine")
        func request(_ revision: Int, method: String, params: [String: Any]) -> [String: Any] {
            state(source: "desktop", change: patches(base: revision - 1, revision: revision, [
                ["op": "replace", "path": ["requests"], "value": [
                    ["id": revision, "method": method, "params": params]
                ]]
            ]))
        }
        let elicitation = "mcpServer/elicitation/request"
        let input = "item/tool/requestUserInput"
        _ = feed.consume(request(5, method: elicitation, params: ["threadId": thread]), clientID: "mine")
        XCTAssertEqual(feed.threads.first?.turns.last?.status, .waiting)
        XCTAssertEqual(feed.threads.first?.turns.last?.requestID, "5")
        _ = feed.consume(request(6, method: elicitation, params: ["threadId": thread, "turnId": "previous"]), clientID: "mine")
        XCTAssertEqual(feed.threads.first?.turns.last?.status, .running)
        _ = feed.consume(request(7, method: elicitation, params: ["threadId": thread, "hostId": "other"]), clientID: "mine")
        XCTAssertEqual(feed.threads.first?.turns.last?.status, .running)
        _ = feed.consume(request(8, method: "item/tool/call", params: ["threadId": thread, "turnId": "current"]), clientID: "mine")
        XCTAssertEqual(feed.threads.first?.turns.last?.status, .running)
        _ = feed.consume(request(9, method: input, params: [
            "threadId": thread, "turnId": "current", "isBlocking": false
        ]), clientID: "mine")
        XCTAssertEqual(feed.threads.first?.turns.last?.status, .waiting)
        XCTAssertEqual(feed.threads.first?.turns.last?.requestID, "remote-nonblocking-input:9")
        _ = feed.consume(state(source: "desktop", change: patches(base: 9, revision: 10, [
            ["op": "replace", "path": ["requests", 0, "completed"] as [Any], "value": true]
        ])), clientID: "mine")
        XCTAssertEqual(feed.threads.first?.turns.last?.status, .running)

        let dynamic = "item/tool/call"
        let optionPicker: [String: Any] = ["threadId": thread, "turnId": "current", "tool": "request_option_picker"]
        _ = feed.consume(request(11, method: dynamic, params: optionPicker), clientID: "mine")
        XCTAssertEqual(feed.threads.first?.turns.last?.status, .running)
        _ = feed.consume(request(12, method: dynamic, params: optionPicker.merging([
            "arguments": ["question": "Pick one", "options": [["label": "A"]]]
        ]) { _, new in new }), clientID: "mine")
        XCTAssertEqual(feed.threads.first?.turns.last?.requestID, "12")
        _ = feed.consume(request(13, method: dynamic, params: [
            "threadId": thread, "turnId": "current", "tool": "request_onboarding_input",
            "arguments": ["questions": [["id": "choice", "question": "Pick one", "options": [
                ["label": "A"], ["label": "B"]
            ]]]]
        ]), clientID: "mine")
        XCTAssertEqual(feed.threads.first?.turns.last?.requestID, "13")
    }

    func testPendingNonBlockingNativeInputCanOutliveTurnCompletion() {
        var feed = CodexRemoteStream()
        _ = feed.consume(following(host: host, source: "desktop"), clientID: "mine")
        _ = feed.consume(state(source: "desktop", change: snapshot(status: "completed", items: [
            ["type": "agentMessage", "phase": "final_answer", "text": "Which option would you prefer?"]
        ])), clientID: "mine")
        XCTAssertEqual(feed.threads.first?.turns.last?.asksForReply, true)
        _ = feed.consume(state(source: "desktop", change: patches(base: 4, revision: 5, [
            ["op": "replace", "path": ["threadRuntimeStatus", "type"], "value": "idle"],
            ["op": "add", "path": ["requests", 0] as [Any], "value": [
                "id": "native", "method": "item/tool/requestUserInput",
                "params": ["threadId": thread, "turnId": "current", "isBlocking": false]
            ]]
        ])), clientID: "mine")
        XCTAssertEqual(feed.threads.first?.turns.last?.status, .waiting)
        XCTAssertTrue(CodexRemoteStream.isNonblockingInput(feed.threads.first?.turns.last?.requestID))
        _ = feed.consume(state(source: "desktop", change: patches(base: 5, revision: 6, [
            ["op": "remove", "path": ["requests", 0] as [Any]]
        ])), clientID: "mine")
        XCTAssertEqual(feed.threads.first?.turns.last?.status, .completed)
        XCTAssertEqual(feed.threads.first?.turns.last?.asksForReply, false)
        XCTAssertNil(feed.threads.first?.turns.last?.requestID)
    }

    func testCompletedFinalQuestionRequiresAnExplicitFinalAnswer() {
        let question = "选择框已弹出。我等你选 A 或 B。"
        var feed = CodexRemoteStream()
        _ = feed.consume(following(host: host, source: "desktop"), clientID: "mine")
        for (offset, phase) in ["commentary", "final_answer"].enumerated() {
            let change = snapshot(status: "completed", items: [
                ["type": "agentMessage", "phase": phase, "text": question]
            ], revision: 4 + offset)
            _ = feed.consume(state(source: "desktop", change: change), clientID: "mine")
            XCTAssertEqual(feed.threads.first?.turns.last?.status, .completed)
            XCTAssertEqual(feed.threads.first?.turns.last?.asksForReply, phase == "final_answer")
        }
    }

    func testRemoteAsyncPickerOutlivesCompletionAndOnlyMatchingRepliesClearIt() throws {
        let picker: [String: Any] = [
            "id": "call_picker", "type": "agentMessage", "phase": "final_answer", "delivery": "async",
            "text": "你想选 A 还是 B？\n- A\n- B",
            "questions": [["title": "你想选 A 还是 B？", "options": ["A", "B"]], ["title": "第二题", "options": []]]
        ]
        let closing: [String: Any] = [
            "type": "agentMessage", "phase": "final_answer", "text": "请在界面中选择 A 或 B。"
        ]
        func reply(_ call: String, _ index: Int, steeringStatus: String? = nil) -> [String: Any] {
            let itemID = "[\"request_user_input_async\",\"\(call)\",\(index)]"
            let encoded = try! JSONEncoder().encode([
                ["questionItemId": itemID, "question": "ignored", "answer": "A"]
            ])
            let envelope = "<send_user_message_question_reply>\n"
                + String(decoding: encoded, as: UTF8.self) + "\n</send_user_message_question_reply>"
            let input = [["type": "text", "text": envelope]]
            if let steeringStatus {
                return ["type": "steeringUserMessage", "status": steeringStatus, "input": input]
            }
            return ["type": "userMessage", "content": input]
        }

        var feed = CodexRemoteStream()
        _ = feed.consume(following(host: host, source: "desktop"), clientID: "mine")
        var hanger = HangerState()
        func apply(_ turn: CodexRemoteTurn) -> Bool {
            hanger.apply([ThreadObservation(
                threadID: thread, title: "询问选择 A 或 B", projectName: "PowerBI",
                turnID: turn.turnID, status: turn.status, updatedAt: turn.happenedAt,
                requestID: turn.requestID, hostID: host
            )], scope: .remote)
        }
        _ = feed.consume(state(source: "desktop", change: snapshot()), clientID: "mine")
        _ = apply(try XCTUnwrap(feed.threads.first?.turns.last))
        // A checkpoint from an earlier install already showed green for this same turn.
        _ = feed.consume(state(source: "desktop", change: snapshot(status: "completed", revision: 5)), clientID: "mine")
        _ = apply(try XCTUnwrap(feed.threads.first?.turns.last))
        XCTAssertEqual(hanger.cards.first?.status, .completed)

        for (offset, replies) in [
            [],
            [reply("other_call", 0), reply("call_picker", 0, steeringStatus: "pending")],
            [reply("call_picker", 0)]
        ].enumerated() {
            let change = snapshot(status: "completed", items: [picker, closing] + replies, revision: 6 + offset)
            _ = feed.consume(state(source: "desktop", change: change), clientID: "mine")
            let turn = try XCTUnwrap(feed.threads.first?.turns.last)
            XCTAssertEqual(turn.status, .waiting)
            XCTAssertTrue(CodexRemoteStream.isNonblockingInput(turn.requestID))
            XCTAssertFalse(turn.asksForReply)
            XCTAssertEqual(apply(turn), offset == 0)
            XCTAssertEqual(hanger.cards.first?.status, .waiting)
        }

        let partialInLaterTurn = snapshot(status: "completed", items: [picker, closing], revision: 9,
                                         laterItems: [reply("call_picker", 0)])
        _ = feed.consume(state(source: "desktop", change: partialInLaterTurn), clientID: "mine")
        let partiallyAnswered = try XCTUnwrap(feed.threads.first)
        XCTAssertEqual(partiallyAnswered.turnsForObservation(trackedTurnID: nil).map(\.turnID), ["later"])
        let stillWaiting = partiallyAnswered.turnsForObservation(trackedTurnID: "current")
        XCTAssertEqual(stillWaiting.map(\.turnID), ["current"])
        XCTAssertEqual(stillWaiting.map(\.status), [.waiting])

        let nextPicker = picker.merging(["id": "call_new"]) { _, new in new }
        let newerQuestion = snapshot(status: "completed", items: [picker, closing], revision: 10,
                                     laterItems: [reply("call_picker", 0), nextPicker])
        _ = feed.consume(state(source: "desktop", change: newerQuestion), clientID: "mine")
        let bothPending = try XCTUnwrap(feed.threads.first)
        XCTAssertEqual(bothPending.turns.last?.status, .waiting)
        XCTAssertEqual(bothPending.turnsForObservation(trackedTurnID: "current").map(\.turnID), ["current"])
        var alternateFeed = feed

        let answered = snapshot(status: "completed", items: [picker, closing], revision: 11, laterItems: [
            reply("call_picker", 0), nextPicker, reply("call_picker", 1, steeringStatus: "accepted")
        ])
        _ = feed.consume(state(source: "desktop", change: answered), clientID: "mine")
        let observed = try XCTUnwrap(feed.threads.first).turnsForObservation(trackedTurnID: "current")
        XCTAssertEqual(observed.map(\.turnID), ["current", "later"])
        let terminal = try XCTUnwrap(observed.first)
        XCTAssertEqual(terminal.status, .completed)
        XCTAssertTrue(terminal.hadPendingInputAfterCompletion)
        XCTAssertFalse(terminal.asksForReply)
        XCTAssertFalse(apply(terminal))
        XCTAssertTrue(hanger.cards.isEmpty)
        XCTAssertEqual(observed.last?.status, .waiting)

        let onlyNewAnswer = snapshot(status: "completed", items: [picker, closing], revision: 11, laterItems: [
            reply("call_picker", 0), nextPicker, reply("call_new", 0), reply("call_new", 1)
        ])
        _ = alternateFeed.consume(state(source: "desktop", change: onlyNewAnswer), clientID: "mine")
        let remaining = try XCTUnwrap(alternateFeed.threads.first).turnsForObservation(trackedTurnID: "current")
        XCTAssertEqual(remaining.map(\.turnID), ["current"])
        XCTAssertEqual(remaining.map(\.status), [.waiting])
    }

    func testCompletionProjectsLateFinalTextAfterOneSnapshotRequest() {
        var feed = CodexRemoteStream()
        _ = feed.consume(following(host: host, source: "desktop"), clientID: "mine")
        _ = feed.consume(state(source: "desktop", change: snapshot(items: [
            ["type": "agentMessage", "phase": "final_answer", "text": ""]
        ])), clientID: "mine")
        let first = DispatchTime.now()
        let itemPath: [Any] = ["turnHistory", "history", "entitiesByKey", "tail:current", "items", 0]
        let statusPath = ["turnHistory", "history", "entitiesByKey", "tail:current", "status"]
        let requests = feed.consume(state(source: "desktop", change: patches(base: 4, revision: 5, [
            ["op": "replace", "path": statusPath, "value": "completed"]
        ])), clientID: "mine", now: first)
        XCTAssertEqual(requests.map(\.following), [true])
        XCTAssertEqual(feed.threads(at: first).first?.turns.last?.status, .running)
        let snapshotRequests = feed.consume(state(source: "desktop", change: snapshot(status: "completed", items: [
            ["type": "agentMessage", "phase": "final_answer", "text": ""]
        ], revision: 5)), clientID: "mine", now: first + 0.05)
        XCTAssertTrue(snapshotRequests.isEmpty)
        XCTAssertEqual(feed.threads(at: first + 0.05).first?.turns.last?.status, .running)
        XCTAssertEqual(feed.threads(at: first + 1).first?.turns.last?.status, .completed)
        XCTAssertEqual(feed.threads(at: first + 1).first?.turns.last?.asksForReply, false)

        let additionalRequests = feed.consume(state(source: "desktop", change: patches(base: 5, revision: 6, [
            ["op": "replace", "path": itemPath + ["text"], "value": "Which option would you prefer?"]
        ])), clientID: "mine", now: first + 0.1)
        XCTAssertTrue(additionalRequests.isEmpty)
        XCTAssertEqual(feed.threads(at: first + 0.1).first?.turns.last?.status, .completed)
        XCTAssertEqual(feed.threads(at: first + 0.1).first?.turns.last?.asksForReply, true)
    }

    func testRevisionGapHidesStaleStateAndAsksSamePeerForSnapshot() {
        var feed = CodexRemoteStream()
        _ = feed.consume(following(host: host, source: "desktop"), clientID: "mine")
        _ = feed.consume(state(source: "desktop", change: snapshot()), clientID: "mine")
        let gap = state(source: "desktop", change: patches(base: 5, revision: 6, []))
        let resubscribe = feed.consume(gap, clientID: "mine")
        XCTAssertEqual(resubscribe.map(\.following), [true])
        XCTAssertEqual(resubscribe.first?.peer, "desktop")
        XCTAssertTrue(feed.threads.isEmpty)
        XCTAssertTrue(feed.consume(gap, clientID: "mine").isEmpty)
        _ = feed.consume(state(source: "desktop", change: snapshot()), clientID: "mine")
        XCTAssertEqual(feed.threads.count, 1)
    }

    func testFramerHandlesFragmentationAndRejectsOversizedFrames() throws {
        var frames = CodexRemoteFrames()
        let message = try XCTUnwrap(CodexRemoteFrames.encode(["type": "response", "message": "你好"]))
        XCTAssertTrue(try frames.append(message.prefix(3)).isEmpty)
        XCTAssertTrue(try frames.append(message.dropFirst(3).prefix(3)).isEmpty)
        let result = try frames.append(message.dropFirst(6) + message)
        XCTAssertEqual(result.count, 2)
        let object = try JSONSerialization.jsonObject(with: result[0]) as? [String: String]
        XCTAssertEqual(object?["message"], "你好")
        XCTAssertThrowsError(try frames.append(Data([0xff, 0xff, 0xff, 0xff])))
    }

    func testUnixSocketSendsOnlyInitializeAndTargetedFollowing() throws {
        let path = "/tmp/cth-\(UUID().uuidString).sock"
        let listener = try Self.listen(at: path)
        defer {
            Darwin.close(listener)
            Darwin.unlink(path)
        }
        let feed = CodexRemoteFeed(socketPath: path)
        defer { feed.stop() }
        let wrappedUp = expectation(description: "The server receives the targeted unsubscribe")
        let discovery = following(host: host, source: "desktop")
        let published = state(source: "desktop", change: snapshot())
        DispatchQueue.global().async {
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { return XCTFail("Mock accept failed") }
            defer { Darwin.close(client) }
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            Darwin.setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            do {
                let initialize = try Self.receive(client)
                XCTAssertEqual(initialize["type"] as? String, "request")
                XCTAssertEqual(initialize["method"] as? String, "initialize")
                XCTAssertEqual(initialize["version"] as? Int, 0)
                XCTAssertEqual(initialize["sourceClientId"] as? String, "")
                let params = initialize["params"] as? [String: String]
                XCTAssertEqual(params?["clientType"], "flowcontext-thread-hanger")
                let id = try XCTUnwrap(initialize["requestId"] as? String)
                XCTAssertNotNil(UUID(uuidString: id))
                let response = try XCTUnwrap(CodexRemoteFrames.encode(
                    ["type": "response", "requestId": id, "result": ["clientId": "mine"]]
                ))
                let announce = try XCTUnwrap(CodexRemoteFrames.encode(discovery))
                try Self.send(response.prefix(2), to: client)
                try Self.send(response.dropFirst(2) + announce, to: client)
                for following in [true, false] {
                    if !following {
                        try Self.send(XCTUnwrap(CodexRemoteFrames.encode(published)), to: client)
                    }
                    let message = try Self.receive(client)
                    XCTAssertEqual(message["type"] as? String, "broadcast")
                    XCTAssertEqual(message["method"] as? String, "thread-stream-following-changed")
                    XCTAssertEqual(message["sourceClientId"] as? String, "mine")
                    XCTAssertEqual(message["targetClientIds"] as? [String], ["desktop"])
                    let fields = try XCTUnwrap(message["params"] as? [String: Any])
                    XCTAssertEqual(fields["following"] as? Bool, following)
                    let discovered = discovery["params"] as? [String: Any]
                    XCTAssertEqual(fields["hostId"] as? String, discovered?["hostId"] as? String)
                    XCTAssertEqual(fields["conversationId"] as? String, discovered?["conversationId"] as? String)
                }
            } catch {
                XCTFail("Mock wire verification failed: \(error)")
            }
            wrappedUp.fulfill()
        }

        var threads = feed.threads()
        let deadline = Date().addingTimeInterval(2)
        while threads.isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            threads = feed.threads()
        }
        XCTAssertEqual(threads.map(\.threadID), [thread])
        feed.stop()
        wait(for: [wrappedUp], timeout: 3)
    }

    private enum MockError: Error { case socket, read, write }

    private static func listen(at path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MockError.socket }
        var address = sockaddr_un()
        let bytes = path.utf8CString
        address.sun_len = UInt8(bytes.count + 2)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { destination.copyBytes(from: $0) }
        }
        let length = socklen_t(address.sun_len)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw MockError.socket
        }
        return fd
    }

    private static func receive(_ fd: Int32) throws -> [String: Any] {
        func read(_ size: Int) throws -> Data {
            var data = Data(count: size)
            var received = 0
            while received < size {
                let length = data.withUnsafeMutableBytes {
                    Darwin.recv(fd, $0.baseAddress?.advanced(by: received), size - received, 0)
                }
                guard length > 0 else { throw MockError.read }
                received += length
            }
            return data
        }
        let header = try read(4)
        let length = header.enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
        guard (1...4096).contains(length),
              let message = try JSONSerialization.jsonObject(with: read(length)) as? [String: Any] else {
            throw MockError.read
        }
        return message
    }

    private static func send(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard Darwin.send(fd, bytes.baseAddress, data.count, 0) == data.count else { throw MockError.write }
        }
    }

    private func following(host: String, source: String, target: String = "mine",
                           following: Bool = true) -> [String: Any] {
        ["type": "broadcast", "method": "thread-stream-following-changed", "version": 1,
         "sourceClientId": source, "targetClientIds": [target],
         "params": ["hostId": host, "conversationId": thread, "following": following]]
    }

    private func state(host: String? = nil, source: String, target: String = "mine",
                       change: [String: Any]) -> [String: Any] {
        ["type": "broadcast", "method": "thread-stream-state-changed", "version": 13,
         "sourceClientId": source, "targetClientIds": [target],
         "params": ["hostId": host ?? self.host, "conversationId": thread, "change": change]]
    }

    private func snapshot(host: String? = nil, status: String = "inProgress",
                          items: [[String: Any]] = [], revision: Int = 4,
                          laterItems: [[String: Any]]? = nil) -> [String: Any] {
        var entities: [String: Any] = [
            "turn:previous": ["turnId": "previous", "turnStartedAtMs": 1_790_000_000_000,
                              "status": "completed", "durationMs": 1000],
            "tail:current": ["turnId": "current", "turnStartedAtMs": 1_790_000_001_000,
                             "status": status, "items": items],
            "turn:child": ["turnId": "child", "rootTurnId": "current",
                           "turnStartedAtMs": 1_790_000_002_000, "status": "failed"]
        ]
        if let laterItems {
            entities["tail:later"] = [
                "turnId": "later", "status": "completed", "turnStartedAtMs": 1_790_000_003_000,
                "durationMs": 3000, "items": laterItems
            ]
        }
        let conversation: [String: Any] = [
            "id": thread, "hostId": host ?? self.host, "title": "Remote title", "cwd": "/remote/work",
            "updatedAt": 1_790_000_001_000, "threadRuntimeStatus": ["type": "active", "activeFlags": []],
            "requests": [], "turns": [],
            "turnHistory": ["kind": "canonical", "history": ["entitiesByKey": entities]]
        ]
        return ["type": "snapshot", "revision": revision, "conversationState": conversation]
    }

    private func patches(base: Int, revision: Int, _ patches: [[String: Any]]) -> [String: Any] {
        ["type": "patches", "baseRevision": base, "revision": revision, "patches": patches]
    }
}
