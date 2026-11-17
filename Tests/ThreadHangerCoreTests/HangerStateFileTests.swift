import Foundation
import XCTest
@testable import ThreadHangerCore

final class HangerStateFileTests: XCTestCase {
    func testRecentCountUsesDefaultForOldFilesAndClampsDevicePreference() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = HangerStateFile(directory: directory)
        let json = directory.appendingPathComponent("device-state.json")
        try Data(#"{"preferences":{"isPaused":true,"isMonitoring":false,"highlightSeconds":7},"checkpoints":{}}"#.utf8)
            .write(to: json)
        var state = try file.read()
        XCTAssertEqual(state.preferences.recentThreadCount, 5)
        XCTAssertTrue(state.preferences.isPaused)
        XCTAssertFalse(state.preferences.isMonitoring)
        XCTAssertEqual(state.preferences.highlightSeconds, 7)

        state.preferences.recentThreadCount = 99
        XCTAssertEqual(state.preferences.recentThreadCount, 10)
        try file.write(state)
        XCTAssertEqual(try file.read().preferences.recentThreadCount, 10)
        try Data(#"{"preferences":{"isPaused":false,"isMonitoring":true,"highlightSeconds":5,"recentThreadCount":-3},"checkpoints":{}}"#.utf8)
            .write(to: json)
        XCTAssertEqual(try file.read().preferences.recentThreadCount, 0)
    }

    func testStandaloneAndEmbeddedOwnersCannotWriteConcurrently() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let standalone = try HangerProcessLock(directory: directory)
        try withExtendedLifetime(standalone) {
            XCTAssertThrowsError(try HangerProcessLock(directory: directory)) {
                XCTAssertEqual(($0 as? POSIXError)?.code, .EWOULDBLOCK)
            }
            let file = HangerStateFile(directory: directory)
            var state = try file.read()
            state.preferences.isPaused = true
            try file.write(state)
            XCTAssertTrue(try file.read().preferences.isPaused)
        }
    }
}
