import Foundation
import SQLite3
import XCTest
@testable import ThreadHangerCore

final class CodexSourceTests: XCTestCase {
    func testRecentCardsAreBoundedAndUseOnlyValidLocalDesktopMetadata() throws {
        let fixture = try Fixture()
        let old = "019ABCDF-0000-7000-8000-000000000001"
        let first = "019abcdf-0000-7000-8000-000000000002"
        let second = "019abcdf-0000-7000-8000-000000000003"
        let withMilliseconds = "019abcdf-0000-7000-8000-000000000004"
        try fixture.thread(old, updated: fixture.seconds - 100_000)
        try fixture.thread(second, updated: fixture.seconds, updatedMilliseconds: "NULL")
        try fixture.thread(first, updated: fixture.seconds)
        try fixture.thread(withMilliseconds, updated: fixture.seconds - 1, updatedMilliseconds: String(fixture.seconds * 1000 + 1))
        try fixture.thread("019abcdf-0000-7000-8000-000000000005", updated: fixture.seconds + 1, archived: 1)
        try fixture.thread("019abcdf-0000-7000-8000-000000000006", updated: fixture.seconds + 1, threadSource: "subagent")
        try fixture.thread("019abcdf-0000-7000-8000-000000000007", updated: fixture.seconds + 1, origin: "Codex CLI")
        try fixture.thread("019abcdf-0000-7000-8000-000000000008", updated: fixture.seconds + 1, source: "cli")
        try fixture.thread("019abcdf-0000-7000-8000-000000000009", updated: fixture.seconds + 1, parent: "'\(first)'")
        try fixture.thread("019abcdf-0000-7000-8000-00000000000z", updated: fixture.seconds + 1)
        try fixture.thread("019abcdf-0000-7000-800-000000000000", updated: fixture.seconds + 1)
        let older = (10..<20).map { "019abcdf-0000-7000-8000-0000000000\($0)" }
        for id in older {
            try fixture.thread(id, updated: fixture.seconds - 200_000)
        }
        try fixture.history.execute("DROP TABLE thread_turns;")
        try fixture.writeProjectMapping()

        let metadata = fixture.codex.appendingPathComponent("state_5.sqlite")
        let wal = fixture.codex.appendingPathComponent("state_5.sqlite-wal")
        let before = try [Data(contentsOf: metadata), Data(contentsOf: wal)]
        let source = CodexSource(home: fixture.codex)
        let limited = try source.recentCards(limit: 2)
        XCTAssertEqual(limited.map(\.id), [withMilliseconds, first])
        XCTAssertEqual(limited.map(\.projectName), ["Mapped Project", "Mapped Project"])
        XCTAssertTrue(limited.allSatisfy { $0.isRecent && !$0.isUnread && $0.status == .unknown })
        XCTAssertEqual(try source.recentCards(limit: 20).map(\.id), [withMilliseconds, first, second, old] + older)
        XCTAssertEqual(try source.recentCards(limit: 0), [])
        XCTAssertEqual(try [Data(contentsOf: metadata), Data(contentsOf: wal)], before)
    }

    func testRecentCardsSupportMetadataWithoutOptionalColumns() throws {
        let fixture = try Fixture()
        let id = "019abcdf-0000-7000-8000-000000000001"
        try fixture.thread(id, updated: fixture.seconds)
        for column in ["name", "updated_at_ms", "attached_thread_parent_id"] {
            try fixture.state.execute("ALTER TABLE threads DROP COLUMN \(column);")
        }

        let cards = try CodexSource(home: fixture.codex).recentCards(limit: 1)
        XCTAssertEqual(cards.map(\.id), [id])
        XCTAssertEqual(cards.first?.title, "Untitled thread")
        XCTAssertEqual(cards.first?.changedAt, fixture.now)
    }

    func testFindsRecentDesktopUserTurnsAndRecoversTrackedOldTurnFromWAL() throws {
        let fixture = try Fixture()
        try fixture.thread("active", updated: fixture.seconds - 4)
        try fixture.turn("active", "parent", 1, "inProgress", started: fixture.seconds - 5)
        try fixture.turn("active", "internal", 2, "failed", started: fixture.seconds - 4, root: "parent")
        try fixture.thread("old", updated: fixture.seconds - 200_000)
        try fixture.turn("old", "finished", 1, "completed", started: fixture.seconds - 200_100,
                         completed: fixture.seconds - 200_000)
        try fixture.thread("other-old", updated: fixture.seconds - 200_000)
        try fixture.turn("other-old", "finished", 1, "failed", started: fixture.seconds - 200_100,
                         completed: fixture.seconds - 200_000)
        try fixture.thread("automated", updated: fixture.seconds, threadSource: "automation")
        try fixture.turn("automated", "completed", 1, "completed", started: fixture.seconds)
        try fixture.thread("archived", updated: fixture.seconds, archived: 1)
        try fixture.turn("archived", "failed", 1, "failed", started: fixture.seconds)
        try fixture.thread("other-client", updated: fixture.seconds, origin: "codex_cli_rs")
        try fixture.turn("other-client", "running", 1, "inProgress", started: fixture.seconds)
        try fixture.writeProjectMapping()

        let observations = try CodexSource(home: fixture.codex).scan(
            trackedThreadIDs: ["old", "archived", "other-client"], now: fixture.now
        )
        XCTAssertEqual(observations.count, 2)
        let byThread = Dictionary(uniqueKeysWithValues: observations.map { ($0.threadID, $0) })
        XCTAssertEqual(byThread["active"]?.turnID, "parent")
        XCTAssertEqual(byThread["active"]?.status, .running)
        XCTAssertEqual(byThread["active"]?.projectName, "Mapped Project")
        XCTAssertEqual(byThread["active"]?.title, "Thread active")
        XCTAssertEqual(byThread["old"]?.status, .completed)
    }

    func testRecoversExactTrackedTurnBeforeNewerTurnInSameThread() throws {
        let fixture = try Fixture()
        try fixture.thread("thread", updated: fixture.seconds)
        try fixture.turn("thread", "old-turn", 1, "failed", started: fixture.seconds - 100,
                         completed: fixture.seconds - 30)
        try fixture.turn("thread", "new-turn", 2, "inProgress", started: fixture.seconds - 5)

        let observations = try CodexSource(home: fixture.codex).scan(
            trackedThreadIDs: ["thread"], trackedTurnIDsByThread: ["thread": "old-turn"], now: fixture.now
        )
        XCTAssertEqual(observations.map(\.turnID), ["old-turn", "new-turn"])
        XCTAssertEqual(observations.map(\.status), [.failed, .running])
    }

    func testStaleRunningAndUnattributedInterruptionsStayUnknown() throws {
        let fixture = try Fixture()
        try fixture.thread("stale", updated: fixture.seconds - 4_000)
        try fixture.turn("stale", "stale-turn", 1, "inProgress", started: fixture.seconds - 10_000)
        try fixture.thread("unknown-stop", updated: fixture.seconds)
        try fixture.turn("unknown-stop", "interrupted-turn", 1, "interrupted", started: fixture.seconds - 15,
                         completed: fixture.seconds)
        try fixture.thread("user-stop", updated: fixture.seconds)
        try fixture.turn("user-stop", "aborted-turn", 1, "interrupted", started: fixture.seconds - 12,
                         completed: fixture.seconds)
        try fixture.thread("true-failure", updated: fixture.seconds)
        try fixture.turn("true-failure", "failed-turn", 1, "failed", started: fixture.seconds - 20,
                         completed: fixture.seconds)
        try fixture.writeStopLog()

        let source = CodexSource(home: fixture.codex)
        let observations = try source.scan(trackedThreadIDs: [], now: fixture.now)
        let byThread = Dictionary(uniqueKeysWithValues: observations.map { ($0.threadID, $0) })
        XCTAssertEqual(byThread["stale"]?.status, .unknown)
        XCTAssertEqual(byThread["unknown-stop"]?.status, .unknown)
        XCTAssertEqual(byThread["user-stop"]?.status, .interrupted)
        XCTAssertEqual(byThread["true-failure"]?.status, .failed)
        XCTAssertFalse(source.diagnostic.isEmpty)
    }

    func testTailsValidatedRolloutAcrossPartialLinesAndReplacement() throws {
        let fixture = try Fixture()
        let rollout = fixture.codex.appendingPathComponent("sessions/rollout-thread.jsonl")
        try FileManager.default.createDirectory(at: rollout.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fixture.thread("thread", updated: fixture.seconds, rolloutPath: rollout.path)

        let start = """
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn","started_at":\(fixture.seconds)}}
        """
        let source = CodexSource(home: fixture.codex)
        try Data("""
            {"type":"session_meta","payload":{"id":"different-thread"}}
            \(start)

            """.utf8).write(to: rollout)
        XCTAssertTrue(try source.scan(trackedThreadIDs: [], now: fixture.now).isEmpty)

        try Data("""
            {"type":"session_meta","payload":{"id":"thread"}}
            \(start.dropLast())

            """.dropLast().utf8).write(to: rollout, options: .atomic)
        XCTAssertTrue(try source.scan(trackedThreadIDs: [], now: fixture.now).isEmpty)

        let writer = try FileHandle(forWritingTo: rollout)
        defer { try? writer.close() }
        _ = try writer.seekToEnd()
        try writer.write(contentsOf: Data("}\n".utf8))
        let running = try source.scan(trackedThreadIDs: [], now: fixture.now)
        XCTAssertEqual(running.map(\.status), [.running])
        XCTAssertEqual(running.map(\.turnID), ["turn"])

        try writer.write(contentsOf: Data("""
            {"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn"}}

            """.utf8))
        let cold = CodexSource(home: fixture.codex)
        XCTAssertTrue(try cold.scan(trackedThreadIDs: [], now: fixture.now).isEmpty)
        let tracked = try source.scan(
            trackedThreadIDs: ["thread"], trackedTurnIDsByThread: ["thread": "turn"], now: fixture.now
        )
        XCTAssertEqual(tracked.map(\.status), [.unknown])

        try fixture.turn("thread", "turn", 1, "failed", started: fixture.seconds, completed: fixture.seconds)
        XCTAssertEqual(try source.scan(trackedThreadIDs: [], now: fixture.now).map(\.status), [.failed])

        try writer.truncate(atOffset: 0)
        _ = try writer.seekToEnd()
        try writer.write(contentsOf: Data("""
            {"type":"session_meta","payload":{"id":"thread"}}

            """.utf8))
        XCTAssertEqual(try source.scan(trackedThreadIDs: [], now: fixture.now).map(\.status), [.failed])
    }

    func testVerifiedRolloutCompletesTrackedTurnMissingFromVisibleThreadProjection() throws {
        let fixture = try Fixture()
        let rollout = try fixture.userInputRollout(projectedTurn: false)
        let started = fixture.seconds
        try fixture.turn("thread", "old", 1, "completed", started: started - 86_400, completed: started - 86_400)
        try fixture.turn("internal-thread", "turn", 2, "completed", started: started, completed: started + 3)
        try fixture.append(rollout, after: 1, payload: [
            "type": "reasoning", "text": String(repeating: "x", count: 300 * 1024),
        ])
        try fixture.append(rollout, after: 3, type: "event_msg", payload: [
            "type": "task_complete", "turn_id": "turn", "root_turn_id": "turn",
            "started_at": started, "completed_at": started + 3, "last_agent_message": "Finished.",
        ])
        try FileManager.default.setAttributes(
            [.modificationDate: fixture.now.addingTimeInterval(3)], ofItemAtPath: rollout.path
        )

        let now = fixture.now.addingTimeInterval(900)
        let source = CodexSource(home: fixture.codex)
        XCTAssertEqual(try source.scan(trackedThreadIDs: [], now: now).map(\.turnID), ["old"])
        let observed = try source.scan(trackedThreadIDs: ["thread"], trackedTurnIDsByThread: ["thread": "turn"], now: now)
        XCTAssertEqual(observed.map(\.turnID), ["turn"])
        XCTAssertEqual(observed.map(\.status), [.completed])
        XCTAssertEqual(observed.first?.updatedAt, fixture.now.addingTimeInterval(3))
    }

    func testUnrelatedRolloutDoesNotKeepAnUnprojectedTrackedTurnRunning() throws {
        let fixture = try Fixture()
        let rollout = try fixture.userInputRollout(projectedTurn: false)
        try fixture.turn("thread", "turn", 1, "inProgress", started: fixture.seconds - 900)
        try FileManager.default.setAttributes([.modificationDate: fixture.now], ofItemAtPath: rollout.path)
        let now = fixture.now.addingTimeInterval(20)
        let observed = try CodexSource(home: fixture.codex).scan(
            trackedThreadIDs: ["thread"], trackedTurnIDsByThread: ["thread": "different"], now: now
        )
        XCTAssertTrue(observed.contains { $0.turnID == "different" && $0.status == .unknown })
        XCTAssertFalse(observed.contains { $0.status == .running })
    }

    func testRolloutTailResetsWhenFileIsRewrittenBeforeNextPoll() throws {
        let fixture = try Fixture()
        let sessions = fixture.codex.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let rollout = sessions.appendingPathComponent("rollout-thread.jsonl")
        let header = #"{"type":"session_meta","payload":{"id":"thread"}}"# + "\n"
        let start = """
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"old","started_at":\(fixture.seconds)}}

        """
        try Data((header + start).utf8).write(to: rollout)
        let tailer = CodexRolloutTail(sessionsDirectory: sessions)
        XCTAssertEqual(tailer.latestStart(threadID: "thread", rolloutPath: rollout.path)?.turnID, "old")

        let writer = try FileHandle(forWritingTo: rollout)
        defer { try? writer.close() }
        try writer.truncate(atOffset: 0)
        _ = try writer.seekToEnd()
        let mismatched = header.replacingOccurrences(of: "thread", with: "different-thread")
        try writer.write(contentsOf: Data((mismatched + start + start).utf8))
        XCTAssertNil(tailer.latestStart(threadID: "thread", rolloutPath: rollout.path))
    }

    func testTrackedLongTurnStaysRunningWhileVerifiedRolloutContinues() throws {
        let fixture = try Fixture()
        let started = fixture.seconds - 601
        let sessions = fixture.codex.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        var paths: [URL] = []
        for thread in ["projected", "unprojected"] {
            let path = sessions.appendingPathComponent("rollout-\(thread).jsonl")
            paths.append(path)
            try fixture.thread(thread, updated: started, rolloutPath: path.path)
            let jsonl = """
                {"type":"session_meta","payload":{"id":"\(thread)"}}
                {"type":"event_msg","payload":{"type":"task_started","turn_id":"long","started_at":\(started)}}

                """
            try Data(jsonl.utf8).write(to: path)
            try FileManager.default.setAttributes([.modificationDate: fixture.now], ofItemAtPath: path.path)
        }
        try fixture.turn("projected", "long", 1, "inProgress", started: started)

        let source = CodexSource(home: fixture.codex)
        let fresh = try source.scan(trackedThreadIDs: [], now: fixture.now)
        XCTAssertFalse(fresh.contains { $0.status == .running })

        let tracked = ["projected": "long", "unprojected": "long"]
        let continued = try source.scan(
            trackedThreadIDs: Set(tracked.keys), trackedTurnIDsByThread: tracked, now: fixture.now
        )
        XCTAssertEqual(continued.map(\.status), [.running, .running])
        for path in paths {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(started))], ofItemAtPath: path.path
            )
        }
        let stale = try source.scan(
            trackedThreadIDs: Set(tracked.keys), trackedTurnIDsByThread: tracked, now: fixture.now
        )
        XCTAssertEqual(stale.map(\.status), [.unknown, .unknown])
    }

    func testMissingSchemaAndDatabasesAreDiagnosedWithoutCreatingFiles() throws {
        let fixture = try Fixture()
        let source = CodexSource(home: fixture.codex)
        try fixture.state.execute("DROP TABLE threads;")
        XCTAssertThrowsError(try source.scan(trackedThreadIDs: [], now: fixture.now))
        XCTAssertFalse(source.diagnostic.isEmpty)

        let missingDirectory = fixture.root.appendingPathComponent("missing")
        let missing = CodexSource(home: missingDirectory)
        XCTAssertThrowsError(try missing.scan(trackedThreadIDs: [], now: fixture.now))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingDirectory.path))
    }

    func testWaitingForRealAnswerIsPairedByCallIdentityThenReturnsToRunning() throws {
        let fixture = try Fixture()
        let rollout = try fixture.userInputRollout()
        let source = CodexSource(home: fixture.codex)
        var state = HangerState()

        func scan(_ offset: TimeInterval) throws -> ThreadObservation {
            let events = try source.scan(
                trackedThreadIDs: Set(state.trackedTurnIDs.keys),
                trackedTurnIDsByThread: state.trackedTurnIDs,
                now: fixture.now.addingTimeInterval(offset),
                trackedWaitingRequests: state.trackedWaitingRequests
            )
            return try XCTUnwrap(events.first)
        }

        XCTAssertFalse(state.apply([try scan(0)], now: fixture.now))
        XCTAssertEqual(state.cards.first?.status, .running)
        try fixture.append(rollout, after: 1, payload: [
            "type": "function_call", "name": "request_user_input", "call_id": "question", "status": "completed",
        ])
        try fixture.append(rollout, after: 2, payload: ["type": "function_call_output", "call_id": "a-different-call"])
        let asking = try scan(3)
        XCTAssertEqual(asking.status, .waiting)
        XCTAssertEqual(asking.requestID, "question")
        XCTAssertTrue(state.apply([asking], now: fixture.now.addingTimeInterval(3)))
        XCTAssertEqual(state.cards.first?.status, .waiting)
        XCTAssertFalse(state.apply([try scan(4)], now: fixture.now.addingTimeInterval(4)))

        try fixture.append(rollout, after: 5, type: "retained_context", payload: [
            "type": "verified_answer", "call_id": "question", "turn_id": "turn",
        ])
        let answered = try scan(6)
        XCTAssertEqual(answered.status, .running)
        XCTAssertGreaterThan(answered.updatedAt, asking.updatedAt)
        XCTAssertFalse(state.apply([answered], now: fixture.now.addingTimeInterval(6)))
        XCTAssertEqual(state.cards.first?.status, .running)
        XCTAssertFalse(state.hasPendingNotifications)
    }

    func testAsyncInputIsNotAnsweredByAcceptanceOrTaskCompletion() throws {
        let fixture = try Fixture()
        let rollout = try fixture.userInputRollout()
        let source = CodexSource(home: fixture.codex)
        let request = "async-input:call_live"
        func scan(_ offset: TimeInterval, expected: String? = nil) throws -> ThreadObservation {
            try XCTUnwrap(source.scan(
                trackedThreadIDs: ["thread"], trackedTurnIDsByThread: ["thread": "turn"],
                now: fixture.now.addingTimeInterval(offset),
                desktopStartedAt: fixture.now.addingTimeInterval(-60),
                trackedWaitingRequests: expected.map { ["thread": $0] } ?? [:]
            ).last)
        }
        XCTAssertEqual(try scan(0).status, .running)
        try fixture.asyncInput(rollout, after: 1, call: "call_live")
        XCTAssertEqual(try scan(1.5).status, .running)
        try fixture.asyncAcceptance(rollout, after: 2, call: "call_live", accepted: true)
        XCTAssertEqual(try scan(3).requestID, request)
        try fixture.append(rollout, after: 4, type: "event_msg", payload: [
            "type": "task_complete", "turn_id": "turn", "completed_at": fixture.seconds + 4,
            "last_agent_message": "你希望我用方案 A 还是方案 B？",
        ])
        try fixture.completeTurn("turn", after: 4)
        try FileManager.default.setAttributes(
            [.modificationDate: fixture.now.addingTimeInterval(4)], ofItemAtPath: rollout.path
        )
        XCTAssertEqual(try scan(5, expected: request).status, .waiting)
        try fixture.append(rollout, after: 6, payload: [
            "type": "reasoning", "text": String(repeating: "x", count: 300 * 1024),
        ])
        try FileManager.default.setAttributes(
            [.modificationDate: fixture.now.addingTimeInterval(6)], ofItemAtPath: rollout.path
        )
        XCTAssertEqual(try scan(900, expected: request).requestID, request)
        let restarted = try CodexSource(home: fixture.codex).scan(
            trackedThreadIDs: ["thread"], trackedTurnIDsByThread: ["thread": "turn"],
            now: fixture.now.addingTimeInterval(900), desktopStartedAt: fixture.now.addingTimeInterval(850),
            trackedWaitingRequests: ["thread": request]
        )
        XCTAssertEqual(restarted.last?.requestID, request)
        XCTAssertEqual(restarted.last?.turnID, "turn")

        try fixture.append(rollout, after: 901, type: "event_msg", payload: [
            "type": "task_started", "turn_id": "next", "started_at": fixture.seconds + 901,
        ])
        try fixture.turn("thread", "next", 2, "inProgress", started: fixture.seconds + 901)
        try fixture.asyncReply(rollout, after: 902, call: "call_unrelated")
        try fixture.asyncReply(rollout, after: 903, call: "call_live", quoted: true)
        XCTAssertEqual(try scan(904, expected: request).requestID, request)

        try fixture.asyncReply(rollout, after: 905, call: "call_live")
        let resumed = try scan(906, expected: request)
        XCTAssertEqual(resumed.turnID, "next")
        XCTAssertEqual(resumed.status, .running)
        XCTAssertNil(resumed.requestID)
        let restartedAfterReply = try CodexSource(home: fixture.codex).scan(
            trackedThreadIDs: ["thread"], trackedTurnIDsByThread: ["thread": "turn"],
            now: fixture.now.addingTimeInterval(906), trackedWaitingRequests: ["thread": request]
        )
        XCTAssertEqual(restartedAfterReply.last?.turnID, "next")
        XCTAssertEqual(restartedAfterReply.last?.status, .running)
    }

    func testAsyncInputRequiresAllMatchingAnswersAndDoesNotReaskTheFinalText() throws {
        let fixture = try Fixture()
        let rollout = try fixture.userInputRollout()
        let source = CodexSource(home: fixture.codex)
        func scan(_ offset: TimeInterval) throws -> ThreadObservation {
            try XCTUnwrap(source.scan(
                trackedThreadIDs: ["thread"], trackedTurnIDsByThread: ["thread": "turn"],
                now: fixture.now.addingTimeInterval(offset),
                trackedWaitingRequests: ["thread": "async-input:call_two"]
            ).last)
        }
        try fixture.asyncInput(rollout, after: 1, call: "call_two", questionCount: 2)
        try fixture.asyncAcceptance(rollout, after: 2, call: "call_two", accepted: true)
        try fixture.append(rollout, after: 3, type: "event_msg", payload: [
            "type": "task_complete", "turn_id": "turn", "completed_at": fixture.seconds + 3,
            "last_agent_message": "你希望我用方案 A 还是方案 B？",
        ])
        try fixture.completeTurn("turn", after: 3)
        try fixture.asyncReply(rollout, after: 4, call: "call_two")
        try fixture.asyncReply(rollout, after: 5, call: "call_two", index: 2)
        XCTAssertEqual(try scan(6).status, .waiting)
        try fixture.asyncReply(rollout, after: 7, call: "call_two", index: 1)
        let answered = try scan(8)
        XCTAssertEqual(answered.status, .completed)
        XCTAssertNil(answered.requestID)
    }

    func testAsyncInputDoesNotReplayOldOrRejectedRequests() throws {
        let fixture = try Fixture()
        let rollout = try fixture.userInputRollout()
        try fixture.asyncInput(rollout, after: 1, call: "call_rejected")
        try fixture.asyncAcceptance(rollout, after: 2, call: "call_rejected", accepted: false)
        let source = CodexSource(home: fixture.codex)
        XCTAssertEqual(try source.scan(trackedThreadIDs: [], now: fixture.now.addingTimeInterval(3)).last?.status, .running)
        try fixture.asyncInput(rollout, after: 4, call: "call_old")
        try fixture.asyncAcceptance(rollout, after: 5, call: "call_old", accepted: true)
        let discovered = try CodexSource(home: fixture.codex).scan(
            trackedThreadIDs: [], trackedTurnIDsByThread: [:], now: fixture.now.addingTimeInterval(900),
            desktopStartedAt: fixture.now.addingTimeInterval(6)
        )
        XCTAssertFalse(discovered.contains { $0.status == .waiting })
    }

    func testDefaultModeFinalQuestionStaysWaitingUntilTheNextTurn() throws {
        let fixture = try Fixture()
        let rollout = try fixture.userInputRollout()
        let source = CodexSource(home: fixture.codex)
        var state = HangerState()
        func scan(_ offset: TimeInterval) throws -> [ThreadObservation] {
            try source.scan(
                trackedThreadIDs: Set(state.trackedTurnIDs.keys),
                trackedTurnIDsByThread: state.trackedTurnIDs,
                now: fixture.now.addingTimeInterval(offset),
                trackedWaitingRequests: state.trackedWaitingRequests
            )
        }

        XCTAssertFalse(state.apply(try scan(0), now: fixture.now))
        try fixture.append(rollout, after: 1, type: "event_msg", payload: [
            "type": "task_complete", "turn_id": "turn", "root_turn_id": "turn",
            "completed_at": fixture.seconds + 1, "last_agent_message": "你希望我用方案 A 还是方案 B？",
        ])
        try fixture.completeTurn("turn", after: 1)
        try FileManager.default.setAttributes(
            [.modificationDate: fixture.now.addingTimeInterval(1)], ofItemAtPath: rollout.path
        )

        let untracked = try source.scan(trackedThreadIDs: [], now: fixture.now.addingTimeInterval(2))
        XCTAssertEqual(untracked.first?.status, .completed)
        var newMonitor = HangerState()
        XCTAssertFalse(newMonitor.apply(untracked, now: fixture.now.addingTimeInterval(2)))
        XCTAssertTrue(newMonitor.cards.isEmpty)

        let waiting = try scan(2)
        XCTAssertEqual(waiting.first?.status, .waiting)
        XCTAssertNotNil(waiting.first?.requestID)
        XCTAssertTrue(state.apply(waiting, now: fixture.now.addingTimeInterval(2)))
        let notification = state.cards.first?.notificationID
        XCTAssertEqual(state.cards.first?.status, .waiting)

        let quiet = try scan(901)
        XCTAssertEqual(quiet.first?.status, .waiting)
        XCTAssertFalse(state.apply(quiet, now: fixture.now.addingTimeInterval(901)))
        XCTAssertEqual(state.cards.first?.notificationID, notification)

        let moved = fixture.codex.appendingPathComponent("unavailable.jsonl")
        try FileManager.default.moveItem(at: rollout, to: moved)
        let unavailable = try scan(902)
        XCTAssertEqual(unavailable.first?.status, .unknown)
        XCTAssertFalse(state.apply(unavailable, now: fixture.now.addingTimeInterval(902)))
        try FileManager.default.moveItem(at: moved, to: rollout)
        XCTAssertFalse(state.apply(try scan(903), now: fixture.now.addingTimeInterval(903)))
        XCTAssertEqual(state.cards.first?.notificationID, notification)

        try fixture.append(rollout, after: 904, type: "event_msg", payload: [
            "type": "task_started", "turn_id": "next", "started_at": fixture.seconds + 904,
        ])
        XCTAssertFalse(state.apply(try scan(905), now: fixture.now.addingTimeInterval(905)))
        XCTAssertEqual(state.cards.first?.turnID, "next")
        XCTAssertEqual(state.cards.first?.status, .running)
        XCTAssertTrue(state.trackedWaitingRequests.isEmpty)
    }

    func testOnlyFinalAssistantTextOfTheLatestCompletedTurnCanWait() throws {
        for item in [
            (phase: "final_answer", terminal: "completed", message: "Which option should I use?", last: nil,
             otherTurn: false, expected: ThreadStatus.waiting),
            (phase: "commentary", terminal: "completed", message: "Which option should I use?", last: nil,
             otherTurn: false, expected: ThreadStatus.completed),
            (phase: "final_answer", terminal: "failed", message: "Which option should I use?", last: nil,
             otherTurn: false, expected: ThreadStatus.failed),
            (phase: "final_answer", terminal: "completed", message: "Which option should I use?", last: "Finished.",
             otherTurn: false, expected: ThreadStatus.completed),
            (phase: "final_answer", terminal: "completed", message: "Which option should I use?", last: nil,
             otherTurn: true, expected: ThreadStatus.completed),
            (phase: "final_answer", terminal: "completed", message: "## What changed?\n\nThe fix is live.", last: nil,
             otherTurn: false, expected: ThreadStatus.completed),
        ] {
            let fixture = try Fixture()
            let rollout = try fixture.userInputRollout()
            try fixture.append(rollout, after: 1, payload: [
                "type": "message", "role": "assistant", "phase": item.phase,
                "content": [["type": "output_text", "text": item.message]],
            ])
            try fixture.append(rollout, after: 2, type: "event_msg", payload: [
                "type": "task_complete", "turn_id": "turn", "completed_at": fixture.seconds + 2,
                "last_agent_message": item.last.map { $0 as Any } ?? NSNull(),
            ])
            try fixture.completeTurn("turn", after: 2, status: item.terminal)
            if item.otherTurn {
                try fixture.turn("thread", "next", 2, "inProgress", started: fixture.seconds + 3)
            }
            let results = try CodexSource(home: fixture.codex).scan(
                trackedThreadIDs: ["thread"], trackedTurnIDsByThread: ["thread": "turn"],
                now: fixture.now.addingTimeInterval(4)
            )
            XCTAssertEqual(results.first?.status, item.expected, "\(item)")
        }
    }

    func testOutstandingAnswerSurvivesSilenceButNotADesktopRestart() throws {
        let fixture = try Fixture()
        let rollout = try fixture.userInputRollout()
        try fixture.append(rollout, after: 1, payload: [
            "type": "function_call", "name": "request_user_input", "call_id": "question",
        ])
        try FileManager.default.setAttributes(
            [.modificationDate: fixture.now.addingTimeInterval(1)], ofItemAtPath: rollout.path
        )
        let source = CodexSource(home: fixture.codex)
        let wait = try source.scan(
            trackedThreadIDs: [], trackedTurnIDsByThread: [:],
            now: fixture.now.addingTimeInterval(900), desktopStartedAt: fixture.now.addingTimeInterval(-60)
        )
        XCTAssertEqual(wait.first?.status, .waiting)
        var state = HangerState()
        XCTAssertTrue(state.apply(wait, now: fixture.now.addingTimeInterval(900)))
        let restarted = try source.scan(
            trackedThreadIDs: ["thread"], trackedTurnIDsByThread: ["thread": "turn"],
            now: fixture.now.addingTimeInterval(902), desktopStartedAt: fixture.now.addingTimeInterval(901)
        )
        XCTAssertEqual(restarted.first?.status, .unknown)
        XCTAssertFalse(state.apply(restarted, now: fixture.now.addingTimeInterval(902)))
        XCTAssertTrue(state.cards.isEmpty)
    }

    func testAlreadyResolvedAnswerAndOrdinaryEscalationAreNotWaiting() throws {
        let fixture = try Fixture()
        let rollout = try fixture.userInputRollout()
        try fixture.append(rollout, after: 1, payload: [
            "type": "function_call", "name": "request_user_input", "call_id": "question",
        ])
        try fixture.append(rollout, after: 2, payload: [
            "type": "function_call_output", "call_id": "question",
        ])
        try fixture.append(rollout, after: 3, payload: [
            "type": "function_call", "name": "exec_command", "call_id": "shell",
            "arguments": #"{"sandbox_permissions":"require_escalated"}"#,
        ])
        let source = CodexSource(home: fixture.codex)
        let observations = try source.scan(trackedThreadIDs: [], now: fixture.now.addingTimeInterval(4))
        XCTAssertEqual(observations.map(\.status), [.running])
    }

    func testNewWaitSurvivesALargeAppendThatSkipsTheNewTurnStart() throws {
        let fixture = try Fixture()
        let rollout = try fixture.userInputRollout()
        let source = CodexSource(home: fixture.codex)
        XCTAssertEqual(try source.scan(trackedThreadIDs: [], now: fixture.now).first?.turnID, "turn")
        try fixture.turn("thread", "next", 2, "inProgress", started: fixture.seconds + 1)
        try fixture.append(rollout, after: 1, type: "event_msg", payload: [
            "type": "task_started", "turn_id": "next", "started_at": fixture.seconds + 1,
        ])
        try fixture.append(rollout, after: 2, payload: [
            "type": "reasoning", "text": String(repeating: "x", count: 272 * 1024),
        ])
        try fixture.append(rollout, after: 3, payload: [
            "type": "function_call", "name": "request_user_input", "call_id": "new-question",
        ])
        let observed = try source.scan(trackedThreadIDs: [], now: fixture.now.addingTimeInterval(4))
        XCTAssertEqual(observed.last?.turnID, "next")
        XCTAssertEqual(observed.last?.status, .waiting)
        XCTAssertEqual(observed.last?.requestID, "new-question")
    }

    func testMissingRolloutHidesUnverifiedWaitWithoutDuplicatingItOnRecovery() throws {
        let fixture = try Fixture()
        let rollout = try fixture.userInputRollout()
        try fixture.append(rollout, after: 1, payload: [
            "type": "function_call", "name": "request_user_input", "call_id": "question",
        ])
        let source = CodexSource(home: fixture.codex)
        var state = HangerState()
        func scan(_ offset: TimeInterval) throws -> [ThreadObservation] {
            try source.scan(
                trackedThreadIDs: Set(state.trackedTurnIDs.keys),
                trackedTurnIDsByThread: state.trackedTurnIDs,
                now: fixture.now.addingTimeInterval(offset),
                trackedWaitingRequests: state.trackedWaitingRequests
            )
        }
        XCTAssertTrue(state.apply(try scan(2), now: fixture.now.addingTimeInterval(2)))
        let original = try XCTUnwrap(state.cards.first)
        let moved = fixture.codex.appendingPathComponent("unavailable.jsonl")
        try FileManager.default.moveItem(at: rollout, to: moved)
        XCTAssertFalse(state.apply(try scan(3), now: fixture.now.addingTimeInterval(3)))
        XCTAssertFalse(state.hasPendingNotifications)
        XCTAssertTrue(state.cards.isEmpty)
        try FileManager.default.moveItem(at: moved, to: rollout)
        XCTAssertFalse(state.apply(try scan(4), now: fixture.now.addingTimeInterval(4)))
        XCTAssertEqual(state.cards.first?.notificationID, original.notificationID)
        XCTAssertTrue(state.hasPendingNotifications)
    }

    private final class Fixture {
        let root: URL
        let codex: URL
        let state: WritableDatabase
        let history: WritableDatabase
        let seconds = 1_784_000_000
        var now: Date { Date(timeIntervalSince1970: TimeInterval(seconds)) }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            codex = root.appendingPathComponent(".codex")
            try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
            state = try WritableDatabase(url: codex.appendingPathComponent("state_5.sqlite"))
            history = try WritableDatabase(url: codex.appendingPathComponent("thread_history_1.sqlite"))
            try state.execute("""
                CREATE TABLE threads(
                    id TEXT PRIMARY KEY, name TEXT, title TEXT, cwd TEXT, rollout_path TEXT,
                    originator TEXT, source TEXT, thread_source TEXT, archived INTEGER,
                    updated_at INTEGER, updated_at_ms INTEGER, attached_thread_parent_id TEXT
                );
                """)
            try history.execute("""
                CREATE TABLE thread_turns(
                    thread_id TEXT, turn_id TEXT, rollout_ordinal INTEGER, status TEXT,
                    started_at INTEGER, completed_at INTEGER, root_turn_id TEXT,
                    PRIMARY KEY(thread_id, turn_id)
                );
                """)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func thread(
            _ id: String, updated: Int, archived: Int = 0, threadSource: String = "user",
            origin: String = "Codex Desktop", rolloutPath: String = "", source: String = "vscode",
            updatedMilliseconds: String? = nil, parent: String = "NULL"
        ) throws {
            try state.execute("""
                INSERT INTO threads VALUES (
                    '\(id)', 'Thread \(id)', 'Raw first prompt', '/workspace/Demo', '\(rolloutPath)',
                    '\(origin)', '\(source)', '\(threadSource)', \(archived), \(updated),
                    \(updatedMilliseconds ?? String(updated * 1000)), \(parent)
                );
                """)
        }

        func turn(_ thread: String, _ turn: String, _ ordinal: Int, _ status: String,
                  started: Int, completed: Int? = nil, root: String? = nil) throws {
            try history.execute("""
                INSERT INTO thread_turns VALUES (
                    '\(thread)', '\(turn)', \(ordinal), '\(status)', \(started),
                    \(completed.map(String.init) ?? "NULL"), \(root.map { "'\($0)'" } ?? "NULL")
                );
                """)
        }

        func userInputRollout(projectedTurn: Bool = true) throws -> URL {
            let path = codex.appendingPathComponent("sessions/rollout-thread.jsonl")
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try thread("thread", updated: seconds, rolloutPath: path.path)
            if projectedTurn { try turn("thread", "turn", 1, "inProgress", started: seconds) }
            let contents = """
                {"type":"session_meta","payload":{"id":"thread"}}
                {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn","root_turn_id":"turn","started_at":\(seconds),"collaboration_mode_kind":"default"}}

                """
            try Data(contents.utf8).write(to: path)
            return path
        }

        func completeTurn(_ id: String, after: Int, status: String = "completed") throws {
            try history.execute("""
                UPDATE thread_turns SET status='\(status)', completed_at=\(seconds + after) WHERE turn_id='\(id)';
                """)
        }

        func asyncInput(_ path: URL, after: TimeInterval, call: String, questionCount: Int = 1) throws {
            let questions = Array(repeating: ["question": "Which option should I use?", "options": [["label": "A"]]] as [String: Any], count: questionCount)
            let arguments = try JSONSerialization.data(withJSONObject: ["questions": questions])
            try append(path, after: after, payload: [
                "type": "function_call", "name": "request_user_input_async", "call_id": call,
                "arguments": String(decoding: arguments, as: UTF8.self),
                "internal_chat_message_metadata_passthrough": ["turn_id": "turn"],
            ])
        }

        func asyncAcceptance(_ path: URL, after: TimeInterval, call: String, accepted: Bool) throws {
            try append(path, after: after, payload: [
                "type": "function_call_output", "call_id": call, "output": "{\"accepted\":\(accepted)}",
            ])
        }

        func asyncReply(_ path: URL, after: TimeInterval, call: String, index: Int = 0, quoted: Bool = false) throws {
            let reply = """
            <send_user_message_question_reply>
            [{"questionItemId":"[\\"request_user_input_async\\",\\"\(call)\\",\(index)]","question":"Which option should I use?","answer":"A"}]
            </send_user_message_question_reply>

            """
            try append(path, after: after, payload: [
                "type": "message", "role": "user",
                "content": [["type": "input_text", "text": (quoted ? "Example:\n" : "") + reply]],
            ])
        }

        func append(_ path: URL, after: TimeInterval, type: String = "response_item", payload: [String: Any]) throws {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let event: [String: Any] = [
                "timestamp": formatter.string(from: now.addingTimeInterval(after)),
                "type": type, "payload": payload,
            ]
            let writer = try FileHandle(forWritingTo: path)
            defer { try? writer.close() }
            try writer.seekToEnd()
            try writer.write(contentsOf: try JSONSerialization.data(withJSONObject: event) + Data([10]))
        }

        func writeProjectMapping() throws {
            let mapping = """
                {"thread-project-assignments":{"active":{"projectKind":"local","projectId":"p"}},
                 "local-projects":{"p":{"name":"Mapped Project","rootPaths":["/workspace/Demo"]}}}
                """
            try Data(mapping.utf8).write(to: codex.appendingPathComponent(".codex-global-state.json"))
        }

        func writeStopLog() throws {
            let timestamp = ISO8601DateFormatter()
            timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let day = String(timestamp.string(from: now).prefix(10)).replacingOccurrences(of: "-", with: "/")
            let logDirectory = root.appendingPathComponent("Library/Logs/com.openai.codex/\(day)")
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            let date = timestamp.string(from: now.addingTimeInterval(-0.1))
            let text = """
                \(date) info [host-app-server-manager] Sending turn interrupt callSite=interruptConversationSelf hostId=local reason=system threadId=unknown-stop turnId=interrupted-turn
                \(date) info [host-app-server-manager] Sending turn interrupt callSite=interruptConversationSelf hostId=local reason=user-stop threadId=unknown-stop turnId=different-turn
                \(date) info [host-app-server-manager] Sending turn interrupt callSite=interruptConversationSelf hostId=local reason=user-stop threadId=user-stop turnId=aborted-turn
                """
            try Data(text.utf8).write(to: logDirectory.appendingPathComponent("fixture.log"))
        }
    }

    private final class WritableDatabase {
        var handle: OpaquePointer?

        init(url: URL) throws {
            guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
                throw CocoaError(.fileWriteUnknown)
            }
            try execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
        }

        deinit { sqlite3_close(handle) }

        func execute(_ sql: String) throws {
            let result = sqlite3_exec(handle, sql, nil, nil, nil)
            guard result == SQLITE_OK else {
                throw NSError(domain: "SQLite fixture", code: Int(result), userInfo: [
                    NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))
                ])
            }
        }
    }
}
