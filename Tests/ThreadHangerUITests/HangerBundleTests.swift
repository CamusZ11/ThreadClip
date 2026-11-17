import Foundation
import XCTest
@testable import ThreadClip

final class HangerBundleTests: XCTestCase {
    @MainActor
    func testOnlyStandaloneAppOwnsAMenuBarItem() async {
        let standalone = URL(fileURLWithPath: "/Applications/ThreadClip.app")
        let embedded = URL(fileURLWithPath: "/Applications/FlowContext.app/Contents/Helpers/Codex Thread Hanger.app")
        let executable = URL(fileURLWithPath: "/tmp/ThreadClip")

        XCTAssertTrue(HangerAppDelegate.showsStatusItem(bundleURL: standalone))
        XCTAssertFalse(HangerAppDelegate.showsStatusItem(bundleURL: embedded))
        XCTAssertTrue(HangerAppDelegate.showsStatusItem(bundleURL: executable))
    }
}
