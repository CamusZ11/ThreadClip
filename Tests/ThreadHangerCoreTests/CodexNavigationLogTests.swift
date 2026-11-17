import Foundation
import XCTest
@testable import ThreadHangerCore

final class CodexNavigationLogTests: XCTestCase {
    private let target = "f6bf20ef-b28a-4c8c-9169-3fe9cc41b1e2"
    private let other = "3a485773-a269-47c6-a2c5-f392c2bc93d1"
    private let pid: Int32 = 812
    private let formatter = ISO8601DateFormatter()

    private func date(_ second: Int) -> Date {
        formatter.date(from: String(format: "2026-11-16T09:45:%02dZ", second))!
    }

    private func route(_ id: String, at time: Int, window: Int = 2, auxiliary: Bool = false, hostID: String? = nil) -> [String] {
        let stamp = String(format: "2026-11-16T09:45:%02d.000Z", time)
        let prefix = "\(stamp) info [electron-message-handler] IAB_LIFECYCLE"
        let query = hostID.map { "?hostId=\($0.replacingOccurrences(of: ":", with: "%3A"))" } ?? ""
        let sync = "\(prefix) received browser sidebar owner sync browserTabId=null conversationId=client-new-thread:\(other) originWebContentsId=\(window) ownerRoutePath=/local/\(id)\(query) windowId=\(window)"
        let ignored = "\(prefix) ignored browser sidebar owner sync from auxiliary window conversationId=client-new-thread:\(other) originWebContentsId=\(window) windowId=\(window)"
        return auxiliary ? [sync, ignored] : [sync]
    }

    private func response(_ id: String, at time: Int, method: String = "thread/queue/list", error: String = "null") -> String {
        let stamp = String(format: "2026-11-16T09:45:%02d.000Z", time)
        return "\(stamp) info [AppServerConnection] response_routed broadcastFallback=false conversationId=\(id) durationMs=20 errorCode=\(error) hadPending=true method=\(method) originWebcontentsId=null"
    }

    private func evidence(
        _ lines: [String], otherProcess: [String] = [], allowExisting: Bool = true,
        requestedAt: Int = 10, now: Int = 15, endsWithNewline: Bool = true, hostID: String? = nil
    ) throws -> Bool {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let day = directory.appendingPathComponent("2026/11/16")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let base = "codex-desktop-06b120ef-b28a-4c8c-9169-3fe9cc41b1e2"
        for (index, line) in lines.enumerated() {
            // Individual files exercise the merge across log rotation.
            let path = day.appendingPathComponent("\(base)-\(pid)-t0-i1-000001-\(index / 3).log")
            if !FileManager.default.fileExists(atPath: path.path) {
                try Data().write(to: path)
            }
            let file = try FileHandle(forWritingTo: path)
            try file.seekToEnd()
            let newline = endsWithNewline || index < lines.count - 1 ? "\n" : ""
            try file.write(contentsOf: Data((line + newline).utf8))
            try file.close()
        }
        if !otherProcess.isEmpty {
            try (otherProcess.joined(separator: "\n") + "\n").write(
                to: day.appendingPathComponent("\(base)-1812-t0-i1-000001-0.log"), atomically: true, encoding: .utf8
            )
        }
        return CodexNavigationLog(directory: directory).confirmsRoute(
            threadID: target, hostID: hostID, processID: pid, processStartedAt: date(0),
            requestedAt: date(requestedAt), now: date(now), allowExistingRoute: allowExisting
        )
    }

    func testConfirmedTargetNeedsBothRendererRouteAndSuccessfulTargetReply() throws {
        XCTAssertTrue(try evidence(route(target, at: 11) + [response(target, at: 12)]))
        XCTAssertTrue(try evidence([response(target, at: 11, method: "thread/read")] + route(target, at: 12)))
        XCTAssertFalse(try evidence(route(target, at: 11)))
        XCTAssertFalse(try evidence([response(target, at: 11)]))
        XCTAssertFalse(try evidence(route(other, at: 11) + [response(target, at: 12)]))
    }

    func testExactTargetReceivedByAnAuxiliaryWindowDoesNotConfirm() throws {
        XCTAssertFalse(try evidence(route(target, at: 11, window: 4, auxiliary: true) + [response(target, at: 12)]))
        XCTAssertTrue(try evidence(
            route(target, at: 11) + route(other, at: 12, window: 4, auxiliary: true) + [response(target, at: 13)]
        ))
        XCTAssertFalse(try evidence(route(target, at: 11), otherProcess: [response(target, at: 12)]))
    }

    func testExplicitLoadFailureCannotBeMaskedByQueueSuccess() throws {
        let failed = route(target, at: 11) + [
            response(target, at: 12, method: "thread/read", error: "-32600"),
            response(target, at: 13)
        ]
        XCTAssertFalse(try evidence(failed))
        XCTAssertTrue(try evidence(failed + [response(target, at: 14, method: "thread/read")]))
        XCTAssertFalse(try evidence(route(target, at: 11) + [response(target, at: 12, error: "-32603")]))
    }

    func testAlreadyShowingSameThreadRequiresAnUnchangedConfirmedRoute() throws {
        let baseline = route(target, at: 4) + [response(target, at: 5)]
        XCTAssertTrue(try evidence(baseline))
        XCTAssertFalse(try evidence(baseline, allowExisting: false))
        XCTAssertFalse(try evidence(baseline + route(other, at: 8)))
        XCTAssertFalse(try evidence(baseline + route(other, at: 8, window: 9)))
        XCTAssertFalse(try evidence(
            route(other, at: 8, window: 9) + route(target, at: 11) + [response(target, at: 12)]
        ))
        XCTAssertTrue(try evidence(baseline + route(target, at: 11)))
        XCTAssertFalse(try evidence(baseline + route(other, at: 8) + route(target, at: 11)))
        XCTAssertFalse(try evidence(baseline + [response(target, at: 12, method: "thread/resume", error: "-32600")]))
    }

    func testTrailingIncompleteLogLineDoesNotConfirm() throws {
        XCTAssertFalse(try evidence(
            route(target, at: 11) + [response(target, at: 12)],
            endsWithNewline: false
        ))
    }

    func testRemoteConfirmationRequiresExactHostAndASuccessfulLoad() throws {
        let host = "remote-control:env_test"
        let remoteRoute = route(target, at: 11, hostID: host)
        let loaded = response(target, at: 12, method: "thread/read")
        XCTAssertTrue(try evidence(remoteRoute + [loaded], hostID: host))
        XCTAssertFalse(try evidence(remoteRoute + [loaded]))
        XCTAssertFalse(try evidence(remoteRoute + [loaded], hostID: "remote-control:env_other"))
        XCTAssertFalse(try evidence(remoteRoute + [response(target, at: 12)], hostID: host))
        XCTAssertFalse(try evidence(
            remoteRoute + [loaded] + route(target, at: 13, hostID: "remote-control:env_other"), hostID: host
        ))
    }
}
