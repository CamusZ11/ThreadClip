import Foundation
import XCTest
@testable import ThreadHangerCore

final class HangerStateTests: XCTestCase {
    func testRestoredCardRefreshesItsTitleEvenWhenAnOlderTurnCannotChangeItsStatus() throws {
        let now = Date()
        var state = HangerState()
        let initial = ThreadObservation(
            threadID: "01a1924c-dfaf-74c2-af9e-747dc611260b",
            title: "Previous title", projectName: "Codex", turnID: "current",
            status: .running, updatedAt: now
        )
        state.apply([initial], now: now)
        state = try JSONDecoder().decode(HangerState.self, from: JSONEncoder().encode(state))

        var older = initial
        older.turnID = "previous"
        older.status = .completed
        older.updatedAt = now.addingTimeInterval(-120)
        older.title = "业务公式作业"
        older.projectName = "All_in_Context"
        XCTAssertFalse(state.apply([older], now: now))
        XCTAssertEqual(state.cards.first?.title, "业务公式作业")
        XCTAssertEqual(state.cards.first?.projectName, "All_in_Context")
        XCTAssertEqual(state.cards.first?.status, .running)
        XCTAssertEqual(state.cards.first?.turnID, "current")
    }

    func testFinalQuestionWaitsOnlyForATrackedTurnAndClearsWhenUserReplies() throws {
        let now = Date()
        var state = HangerState()
        var prompt = ThreadObservation(
            threadID: "thread", title: "Choice", projectName: "Test", turnID: "asked",
            status: .waiting, updatedAt: now, requestID: CodexFollowUpQuestion.requestID(for: "asked")
        )
        XCTAssertFalse(state.apply([prompt], now: now))
        XCTAssertTrue(state.cards.isEmpty)

        var running = prompt
        running.status = .running
        running.requestID = nil
        state.apply([running], now: now)
        XCTAssertTrue(state.apply([prompt], now: now))
        XCTAssertEqual(state.cards.first?.status, .waiting)

        var incompleteProjection = prompt
        incompleteProjection.status = .completed
        incompleteProjection.requestID = nil
        XCTAssertFalse(state.apply([incompleteProjection], now: now))
        XCTAssertEqual(state.cards.first?.status, .waiting)
        XCTAssertTrue(state.markRead(try XCTUnwrap(state.cards.first)))
        state = try JSONDecoder().decode(HangerState.self, from: JSONEncoder().encode(state))
        XCTAssertFalse(state.apply([prompt], now: now))
        XCTAssertTrue(state.cards.isEmpty)

        prompt.turnID = "answered"
        prompt.requestID = nil
        prompt.status = .running
        XCTAssertFalse(state.apply([prompt], now: now))
        XCTAssertEqual(state.cards.first?.status, .running)
        XCTAssertFalse(state.hasPendingNotifications)
    }

    func testLateVerifiedFinalQuestionCanReplaceTheSameUnreadCompletion() throws {
        let now = Date()
        var state = HangerState()
        var terminal = ThreadObservation(
            threadID: "thread", title: "Choice", projectName: "Test", turnID: "asked",
            status: .running, updatedAt: now
        )
        state.apply([terminal], now: now)
        terminal.status = .completed
        XCTAssertTrue(state.apply([terminal], now: now))
        let completion = try XCTUnwrap(state.cards.first)
        terminal.status = .waiting
        terminal.requestID = CodexFollowUpQuestion.requestID(for: terminal.turnID)
        XCTAssertTrue(state.apply([terminal], now: now))
        XCTAssertEqual(state.cards.first?.status, .waiting)
        XCTAssertFalse(state.markRead(completion))
    }

    func testAcceptedLocalAsyncQuestionCanReplaceUnreadCompletionAndKeepsItsIdentity() throws {
        let now = Date()
        var state = HangerState()
        var observation = ThreadObservation(
            threadID: "thread", title: "Choice", projectName: "Test", turnID: "same",
            status: .running, updatedAt: now
        )
        state.apply([observation], now: now)
        observation.status = .completed
        XCTAssertTrue(state.apply([observation], now: now))
        let completion = try XCTUnwrap(state.cards.first)

        observation.status = .waiting
        observation.requestID = "async-input:call_choice"
        observation.updatedAt = now.addingTimeInterval(1)
        XCTAssertTrue(state.apply([observation], now: observation.updatedAt))
        XCTAssertEqual(state.cards.first?.status, .waiting)
        XCTAssertFalse(state.markRead(completion))
        XCTAssertTrue(state.markRead(try XCTUnwrap(state.cards.first)))
        XCTAssertFalse(state.apply([observation], now: observation.updatedAt))
        XCTAssertTrue(state.cards.isEmpty)
        observation.status = .completed
        observation.requestID = nil
        XCTAssertFalse(state.apply([observation], now: observation.updatedAt))
        XCTAssertTrue(state.trackedTurnIDs.isEmpty)
    }

    func testAnsweredRemoteFormDoesNotReappearAsAFinalQuestionAfterRestart() throws {
        let now = Date()
        let host = "remote-control:env_test"
        var state = HangerState()
        var observation = ThreadObservation(
            threadID: "thread", title: "Choice", projectName: "Test", turnID: "asked",
            status: .waiting, updatedAt: now, requestID: "remote-nonblocking-input:42", hostID: host
        )
        XCTAssertTrue(state.apply([observation], scope: .remote, now: now))
        XCTAssertTrue(state.markRead(try XCTUnwrap(state.cards.first)))
        state = try JSONDecoder().decode(HangerState.self, from: JSONEncoder().encode(state))

        observation.requestID = CodexFollowUpQuestion.requestID(for: observation.turnID)
        XCTAssertFalse(state.apply([observation], scope: .remote, now: now))
        XCTAssertFalse(state.apply([observation], scope: .remote, now: now))
        XCTAssertTrue(state.cards.isEmpty)
        XCTAssertTrue(state.remoteTrackedTurnIDs.isEmpty)
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func observation(
        _ status: ThreadStatus, at seconds: TimeInterval, thread: String = "a",
        turn: String = "one", request: String? = nil, hostID: String? = nil
    ) -> ThreadObservation {
        ThreadObservation(
            threadID: thread, title: "An example", projectName: "Project", turnID: turn,
            status: status, updatedAt: date(seconds), requestID: request, hostID: hostID
        )
    }

    func testHistoricalTerminalsAndNewRunningDoNotNotify() {
        var state = HangerState()
        XCTAssertFalse(state.apply([
            observation(.completed, at: 1),
            observation(.failed, at: 2, thread: "other"),
            observation(.running, at: 3, thread: "live")
        ], now: date(3)))
        XCTAssertEqual(state.cards.map(\.id), ["live"])
        XCTAssertFalse(state.cards[0].isUnread)
        XCTAssertEqual(state.trackedTurnIDs, ["live": "one"])
    }

    func testCurrentCardsStayFirstAndReadWaitingThreadsAreExcludedFromRecentCards() throws {
        var state = HangerState()
        state.preferences.recentThreadCount = 1
        XCTAssertTrue(state.apply([
            observation(.waiting, at: 1, thread: "waiting", request: "question"),
            observation(.running, at: 2, thread: "finished"),
            observation(.running, at: 3, thread: "active"),
            observation(.completed, at: 4, thread: "finished")
        ], now: date(5)))
        let waiting = try XCTUnwrap(state.cards.first { $0.id == "waiting" })
        XCTAssertTrue(state.markRead(waiting))
        XCTAssertEqual(state.activeThreadIDs, ["active", "waiting"])

        let history = ["waiting", "active", "finished", "recent", "older"].map { id in
            HangerCard(
                id: id, turnID: "", title: id, projectName: "Project", status: .unknown,
                changedAt: date(6), highlightStartedAt: date(6), notificationID: nil, isRecent: true
            )
        }
        XCTAssertEqual(state.cards(includingRecent: history).map(\.id), ["finished", "active", "recent"])
        XCTAssertEqual(state.cards(includingRecent: history).filter(\.isUnread).map(\.id), ["finished"])
        XCTAssertFalse(state.markRead(history[3]))

        state.preferences.recentThreadCount = 0
        XCTAssertEqual(state.cards(includingRecent: history).map(\.id), ["finished", "active"])

        state.preferences.recentThreadCount = 5
        state.preferences.isMonitoring = false
        XCTAssertEqual(state.cards(includingRecent: history).map(\.id), ["finished"])
    }

    func testOnlyLatestUnreadRequestInTheSameTurnCanBeAcknowledged() throws {
        var state = HangerState()
        XCTAssertTrue(state.apply([observation(.waiting, at: 1, request: "first")], now: date(1)))
        let first = try XCTUnwrap(state.cards.first)
        XCTAssertTrue(state.apply([observation(.waiting, at: 2, request: "second")], now: date(2)))
        XCTAssertFalse(state.markRead(first))
        let second = try XCTUnwrap(state.cards.first)
        XCTAssertTrue(state.markRead(second))
        XCTAssertTrue(state.cards.isEmpty)
        XCTAssertFalse(state.apply([observation(.waiting, at: 3, request: "second")], now: date(3)))
        XCTAssertTrue(state.cards.isEmpty)
        XCTAssertFalse(state.apply([observation(.running, at: 4)], now: date(4)))
        XCTAssertEqual(state.cards.first?.status, .running)
        XCTAssertTrue(state.apply([observation(.waiting, at: 5, request: "third")], now: date(5)))
    }

    func testOlderCallbackCannotAcknowledgeTerminalNotification() throws {
        var state = HangerState()
        XCTAssertTrue(state.apply([observation(.waiting, at: 1)], now: date(1)))
        let waiting = try XCTUnwrap(state.cards.first)
        XCTAssertTrue(state.apply([observation(.completed, at: 2)], now: date(2)))
        XCTAssertFalse(state.markRead(waiting))
        XCTAssertEqual(state.cards.first?.status, .completed)
        let completion = try XCTUnwrap(state.cards.first)
        XCTAssertTrue(state.markRead(completion))
        XCTAssertFalse(state.apply([observation(.completed, at: 2)], now: date(5)))
        XCTAssertTrue(state.cards.isEmpty)
    }

    func testReadCompletionBecomesRecentUntilTheSameThreadNeedsAttentionAgain() throws {
        var state = HangerState()
        XCTAssertFalse(state.apply([observation(.running, at: 1)], now: date(1)))
        XCTAssertTrue(state.apply([observation(.completed, at: 2)], now: date(2)))
        let completion = try XCTUnwrap(state.cards.first)
        let recent = HangerCard(
            id: completion.id, turnID: "", title: completion.title, projectName: completion.projectName,
            status: .unknown, changedAt: date(2), highlightStartedAt: date(2),
            notificationID: nil, isRecent: true
        )
        XCTAssertEqual(state.cards(includingRecent: [recent]), [completion])
        XCTAssertTrue(state.markRead(completion))
        XCTAssertEqual(state.cards(includingRecent: [recent]), [recent])

        XCTAssertTrue(state.apply([
            observation(.waiting, at: 3, turn: "two", request: "new")
        ], now: date(3)))
        let waiting = try XCTUnwrap(state.cards.first)
        XCTAssertEqual(state.cards(includingRecent: [recent]), [waiting])
        XCTAssertFalse(state.markRead(recent))
        XCTAssertFalse(state.markRead(completion))
        XCTAssertTrue(state.markRead(waiting))
        XCTAssertTrue(state.cards(includingRecent: [recent]).isEmpty)
    }

    func testRestartRestoresUnreadAndReconcilesOnlyPreviouslyTrackedTurn() throws {
        var state = HangerState()
        XCTAssertFalse(state.apply([observation(.running, at: 1)], now: date(1)))
        let disk = try JSONEncoder().encode(state)
        XCTAssertFalse(String(decoding: disk, as: UTF8.self).contains("An example"))
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: disk) as? [String: Any])
        let checkpoints = try XCTUnwrap(stored["checkpoints"] as? [String: [String: Any]])
        XCTAssertEqual(Set(checkpoints.keys), ["a"])
        XCTAssertNil(checkpoints["a"]?["hostID"])
        XCTAssertNil(checkpoints["a"]?["threadID"])
        var restored = try JSONDecoder().decode(HangerState.self, from: disk)
        XCTAssertEqual(restored.trackedTurnIDs, ["a": "one"])
        XCTAssertTrue(restored.apply([
            observation(.failed, at: 2),
            observation(.completed, at: 3, turn: "untracked"),
            observation(.completed, at: 3, thread: "old")
        ], now: date(10)))
        XCTAssertEqual(restored.cards.map(\.status), [.failed])
        XCTAssertTrue(restored.cards[0].isHighlighted(until: 5, now: date(14.9)))
        XCTAssertFalse(restored.cards[0].isHighlighted(until: 5, now: date(15)))
        let again = try JSONDecoder().decode(HangerState.self, from: JSONEncoder().encode(restored))
        XCTAssertTrue(again.hasPendingNotifications)
        XCTAssertEqual(again.cards.first?.status, .failed)
    }

    func testNewRunSupersedesOlderTerminalInSameBatch() {
        var state = HangerState()
        XCTAssertFalse(state.apply([observation(.running, at: 1)], now: date(1)))
        XCTAssertFalse(state.apply([
            observation(.completed, at: 2),
            observation(.running, at: 3, turn: "two")
        ], now: date(4)))
        XCTAssertEqual(state.cards.map(\.status), [.running])
        XCTAssertFalse(state.apply([observation(.completed, at: 2)], now: date(4)))
        XCTAssertEqual(state.cards.map(\.turnID), ["two"])
        XCTAssertTrue(state.apply([observation(.completed, at: 5, turn: "two")], now: date(5)))
    }

    func testPauseRecordsAndPersistentlyOrdersNewestPendingFirst() throws {
        var state = HangerState()
        state.preferences.isPaused = true
        XCTAssertFalse(state.apply([observation(.running, at: 1)], now: date(1)))
        XCTAssertFalse(state.apply([
            observation(.completed, at: 2), observation(.waiting, at: 3, thread: "b")
        ], now: date(3)))
        XCTAssertEqual(state.cards.map(\.id), ["b", "a"])
        let restored = try JSONDecoder().decode(HangerState.self, from: JSONEncoder().encode(state))
        XCTAssertTrue(restored.preferences.isPaused)
        XCTAssertTrue(restored.hasPendingNotifications)
    }

    func testInterruptionAndUnknownNeverCreateNotifications() {
        var state = HangerState()
        XCTAssertFalse(state.apply([observation(.running, at: 1)], now: date(1)))
        XCTAssertFalse(state.apply([observation(.interrupted, at: 2)], now: date(2)))
        XCTAssertTrue(state.cards.isEmpty)
        XCTAssertFalse(state.apply([observation(.running, at: 3, turn: "two")], now: date(3)))
        XCTAssertFalse(state.apply([observation(.unknown, at: 4, turn: "two")], now: date(4)))
        XCTAssertTrue(state.cards.isEmpty)
    }

    func testMissingLiveProjectionHidesRunningButRetainsExactTurnForRecovery() {
        var state = HangerState()
        XCTAssertFalse(state.apply([observation(.running, at: 1)], now: date(1)))
        XCTAssertFalse(state.apply([], now: date(2)))
        XCTAssertTrue(state.cards.isEmpty)
        XCTAssertEqual(state.trackedTurnIDs, ["a": "one"])
        XCTAssertTrue(state.apply([observation(.completed, at: 4)], now: date(5)))
        XCTAssertEqual(state.cards.first?.status, .completed)
    }

    func testMissingProjectionNoticeCannotSuppressACommittedTerminalWithEarlierTimestamp() {
        var state = HangerState()
        XCTAssertFalse(state.apply([observation(.running, at: 1)], now: date(1)))
        XCTAssertFalse(state.apply([observation(.unknown, at: 10)], now: date(10)))
        XCTAssertTrue(state.cards.isEmpty)
        XCTAssertTrue(state.apply([observation(.completed, at: 4)], now: date(11)))
        XCTAssertEqual(state.cards.first?.status, .completed)
    }

    func testTheSameThreadOnDifferentHostsHasIndependentCheckpointAndAcknowledgement() throws {
        var state = HangerState()
        let firstHost = "remote-control:alpha"
        let secondHost = "remote-control:bravo"
        let thread = "3a485773-a269-47c6-a2c5-f392c2bc93d1"
        let local = observation(.waiting, at: 1, thread: thread, turn: "local", request: "q")
        let first = observation(.waiting, at: 2, thread: thread, turn: "a", request: "q", hostID: firstHost)
        let second = observation(.waiting, at: 3, thread: thread, turn: "b", request: "q", hostID: secondHost)

        XCTAssertTrue(state.apply([local, first], now: date(4)))
        XCTAssertTrue(state.apply([second, first], scope: .remote, now: date(4)))
        XCTAssertEqual(Set(state.cards.map(\.id)), [thread])
        XCTAssertEqual(Set(state.cards.map(\.identity)), [local.identity, first.identity, second.identity])
        XCTAssertEqual(state.trackedTurnIDs, [thread: "local"])
        XCTAssertEqual(state.trackedWaitingRequests, [thread: "q"])
        XCTAssertEqual(state.remoteTrackedTurnIDs, [first.identity: "a", second.identity: "b"])

        let persisted = try JSONEncoder().encode(state)
        var restored = try JSONDecoder().decode(HangerState.self, from: persisted)
        let firstCard = try XCTUnwrap(state.cards.first { $0.hostID == firstHost })
        XCTAssertTrue(restored.markRead(firstCard))
        XCTAssertFalse(restored.markRead(firstCard))
        XCTAssertEqual(Set(restored.cards.map(\.identity)), [local.identity, second.identity])
        XCTAssertEqual(restored.remoteTrackedTurnIDs, state.remoteTrackedTurnIDs)
    }

    func testMissingRemoteSourceHidesLiveCardsPreservingReadStateAndUnreadTerminals() throws {
        var state = HangerState()
        let host = "remote-control:alpha"
        let waiting = observation(.waiting, at: 1, thread: "waiting", request: "q", hostID: host)
        let read = observation(.waiting, at: 1, thread: "read", request: "q", hostID: host)
        let finished = observation(.completed, at: 2, thread: "finished", hostID: host)
        let historical = observation(.failed, at: 2, thread: "historical", hostID: host)
        XCTAssertTrue(state.apply([observation(.waiting, at: 1, request: "local")], now: date(1)))
        XCTAssertTrue(state.apply([
            waiting, read, observation(.running, at: 1, thread: "finished", hostID: host),
            observation(.running, at: 1, thread: "running", hostID: host)
        ], scope: .remote, now: date(1)))
        let waitingCard = try XCTUnwrap(state.cards.first { $0.id == "waiting" })
        XCTAssertTrue(state.markRead(try XCTUnwrap(state.cards.first { $0.id == "read" })))
        XCTAssertTrue(state.apply([waiting, read, finished, historical,
            observation(.running, at: 1, thread: "running", hostID: host)
        ], scope: .remote, now: date(2)))

        XCTAssertFalse(state.apply([], now: date(3)))
        XCTAssertEqual(Set(state.cards.map(\.id)), ["a", "waiting", "finished", "running"])
        let outageAt: TimeInterval = 3 * 24 * 60 * 60
        XCTAssertFalse(state.apply([observation(.completed, at: 4)], scope: .remote, now: date(outageAt)))
        XCTAssertEqual(Set(state.cards.map(\.id)), ["a", "finished"])
        XCTAssertFalse(state.markRead(waitingCard))
        XCTAssertEqual(state.remoteTrackedTurnIDs[waiting.identity], "one")

        XCTAssertFalse(state.apply([waiting, read, finished], scope: .remote, now: date(outageAt + 1)))
        XCTAssertEqual(Set(state.cards.map(\.id)), ["a", "waiting", "finished"])
        XCTAssertTrue(state.markRead(waitingCard))
        XCTAssertFalse(state.apply([
            observation(.running, at: 7, thread: "waiting", hostID: host), finished
        ], scope: .remote, now: date(outageAt + 2)))
        XCTAssertEqual(state.cards.first?.status, .running)
        XCTAssertTrue(state.apply([
            observation(.failed, at: 8, thread: "waiting", hostID: host), finished
        ], scope: .remote, now: date(outageAt + 3)))
        XCTAssertEqual(state.cards.first?.status, .failed)
        XCTAssertFalse(state.markRead(waitingCard))
    }

    func testHistoryDeduplicatesByHostAndThreadBeforeApplyingTheLimit() {
        var state = HangerState()
        state.preferences.recentThreadCount = 2
        let local = observation(.running, at: 1, thread: "same")
        XCTAssertFalse(state.apply([local], now: date(1)))

        func recent(_ hostID: String?) -> HangerCard {
            HangerCard(
                id: "same", turnID: "", title: "Recent", projectName: "Project",
                status: .unknown, changedAt: date(2), highlightStartedAt: date(2),
                notificationID: nil, isRecent: true, hostID: hostID
            )
        }
        let first = recent("remote-control:alpha")
        let second = recent("remote-control:bravo")
        XCTAssertEqual(
            state.cards(includingRecent: [recent(nil), first, first, second]).map(\.identity),
            [local.identity, first.identity, second.identity]
        )
    }
}
