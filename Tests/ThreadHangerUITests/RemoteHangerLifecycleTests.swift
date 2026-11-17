import Foundation
import ThreadHangerCore
import XCTest
@testable import ThreadClip

final class RemoteHangerLifecycleTests: XCTestCase {
    @MainActor
    func testRemoteTurnThatFinishesBetweenScansCanReplaceAnOlderTrackedTurn() async throws {
        let now = Date()
        var state = HangerState()
        var older = ThreadObservation(
            threadID: "conversation", title: "Remote", projectName: "Remote", turnID: "older",
            status: .running, updatedAt: now.addingTimeInterval(-3), hostID: "remote-control:env_test"
        )
        state.apply([older], scope: .remote, now: now)
        older.status = .completed
        older.updatedAt = now.addingTimeInterval(-2)

        var terminal = older
        terminal.turnID = "newer"
        terminal.status = .failed
        terminal.updatedAt = now
        let started = try XCTUnwrap(HangerRuntime.shortRemoteTurnStart(
            for: terminal, trackedTurnID: state.remoteTrackedTurnIDs[terminal.identity],
            observedActiveAt: now.addingTimeInterval(-1)
        ))
        XCTAssertTrue(state.apply([older, started, terminal], scope: .remote, now: now))
        XCTAssertEqual(state.cards.map(\.turnID), ["newer"])
        XCTAssertEqual(state.cards.map(\.status), [.failed])
        XCTAssertNil(HangerRuntime.shortRemoteTurnStart(
            for: terminal, trackedTurnID: nil, observedActiveAt: nil
        ))
    }
}
