import AppKit
import ThreadHangerCore
import XCTest
@testable import ThreadClip

final class HangerLinkHandoffTests: XCTestCase {
    private func unreadCompletion() throws -> HangerStateFile {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = HangerStateFile(directory: directory)
        let startedAt = Date().addingTimeInterval(-10)
        var observation = ThreadObservation(
            threadID: "f6bf20ef-b28a-4c8c-9169-3fe9cc41b1e2",
            title: "Completed conversation", projectName: "Test", turnID: "test-turn",
            status: .running, updatedAt: startedAt
        )
        var state = HangerState()
        state.apply([observation], now: startedAt)
        observation.status = .completed
        observation.updatedAt = Date()
        state.apply([observation])
        try file.write(state)
        return file
    }

    @MainActor
    func testAcceptedLinkCollapsesBeforeReadConfirmation() async throws {
        let file = try unreadCompletion()
        defer { try? FileManager.default.removeItem(at: file.directory) }
        var callback: HangerRuntime.LinkCompletion?
        let runtime = HangerRuntime(stateFile: file) { _, completion in callback = completion }
        defer { runtime.stop() }
        let card = try XCTUnwrap(runtime.cards.first)

        var collapseCount = 0
        runtime.open(card) { collapseCount += 1 }
        XCTAssertEqual(collapseCount, 0)
        try XCTUnwrap(callback)(.accepted(.current))

        XCTAssertEqual(collapseCount, 1)
        XCTAssertTrue(try file.read().hasPendingNotifications,
                      "A submission receipt must not mark the card as read.")
    }

    @MainActor
    func testFailedOrSupersededHandoffDoesNotCollapse() async throws {
        let file = try unreadCompletion()
        defer { try? FileManager.default.removeItem(at: file.directory) }
        var callbacks: [HangerRuntime.LinkCompletion] = []
        let runtime = HangerRuntime(stateFile: file) { _, completion in callbacks.append(completion) }
        defer { runtime.stop() }
        let card = try XCTUnwrap(runtime.cards.first)

        var collapsed = false
        runtime.open(card) { collapsed = true }
        runtime.open(card) { collapsed = true }
        XCTAssertEqual(callbacks.count, 2)
        callbacks[0](.accepted(.current))
        callbacks[1](.failed)
        XCTAssertFalse(collapsed)
        XCTAssertTrue(try file.read().hasPendingNotifications)
    }
}
