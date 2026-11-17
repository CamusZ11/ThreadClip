import Foundation
import XCTest
@testable import ThreadHangerCore

final class HangerLinkTests: XCTestCase {
    func testOnlyLocalUUIDsBecomeACodexThreadURL() {
        let id = "3a485773-a269-47c6-a2c5-f392c2bc93d1"
        XCTAssertEqual(HangerLink.url(for: id)?.absoluteString, "codex://threads/\(id)")
        XCTAssertNil(HangerLink.url(for: "../other"))
        XCTAssertNil(HangerLink.url(for: id + "?hostId=remote"))
    }

    func testRemoteThreadURLCarriesAValidatedHostQuery() throws {
        let id = "3a485773-a269-47c6-a2c5-f392c2bc93d1"
        let host = "remote-control:env_7-abc"
        let url = try XCTUnwrap(HangerLink.url(for: id, hostID: host))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "codex")
        XCTAssertEqual(components.host, "threads")
        XCTAssertEqual(components.path, "/\(id)")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "hostId", value: host)])
        XCTAssertNil(HangerLink.url(for: id, hostID: "remote-control:"))
        XCTAssertNil(HangerLink.url(for: id, hostID: "remote-control:a&hostId=local"))
        XCTAssertNil(HangerLink.url(for: id, hostID: "remote-control:a%26b"))
        XCTAssertNil(HangerLink.url(for: id, hostID: "untrusted:a"))
        XCTAssertNil(HangerLink.url(for: "../other", hostID: host))
    }

    private func card(_ id: String, status: ThreadStatus, notification: UUID? = UUID()) -> HangerCard {
        let date = Date(timeIntervalSince1970: 1)
        return HangerCard(
            id: id, turnID: "turn", title: id, projectName: "Codex", status: status,
            changedAt: date, highlightStartedAt: date, notificationID: notification
        )
    }

    func testAcceptedCompletionLinkHidesStripEvenWithOtherExistingUnreadCards() {
        let completed = card("a", status: .completed)
        let failed = card("b", status: .failed)
        let cards = [completed, failed]
        XCTAssertTrue(HangerLink.shouldHide(
            card: completed, originalCards: cards, currentCards: cards
        ))
    }

    func testOpeningRunningCardKeepsStripVisible() {
        let running = card("a", status: .running, notification: nil)
        XCTAssertFalse(HangerLink.shouldHide(
            card: running, originalCards: [running], currentCards: [running]
        ))
    }

    func testDelayedLinkReceiptDoesNotHideANewerNotification() {
        let completed = card("a", status: .completed)
        let updated = card("a", status: .failed)
        let newcomer = card("b", status: .completed)
        XCTAssertFalse(HangerLink.shouldHide(
            card: completed, originalCards: [completed], currentCards: [updated]
        ))
        XCTAssertFalse(HangerLink.shouldHide(
            card: completed, originalCards: [completed], currentCards: [completed, newcomer]
        ))
    }

    func testRecentLinkHidesStripUnlessANewNotificationArrives() {
        var recent = card("a", status: .unknown, notification: nil)
        recent.isRecent = true
        let newcomer = card("b", status: .completed)
        XCTAssertTrue(HangerLink.shouldHide(card: recent, originalCards: [recent], currentCards: [recent]))
        XCTAssertFalse(HangerLink.shouldHide(card: recent, originalCards: [recent], currentCards: [recent, newcomer]))
    }

    func testARecentCardFromADifferentHostDoesNotConfirmTheOriginalLink() {
        var local = card("a", status: .unknown, notification: nil)
        local.isRecent = true
        var remote = local
        remote.hostID = "remote-control:alpha"
        XCTAssertFalse(HangerLink.shouldHide(card: remote, originalCards: [remote], currentCards: [local]))
        XCTAssertTrue(HangerLink.shouldHide(card: remote, originalCards: [remote], currentCards: [local, remote]))
    }
}
