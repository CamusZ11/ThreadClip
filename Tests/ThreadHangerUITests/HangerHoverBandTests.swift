import AppKit
import XCTest
@testable import ThreadClip

final class HangerHoverBandTests: XCTestCase {
    @MainActor
    func testOnlyCenterThirdOfTopBandCanTriggerHover() async {
        let topBand = CGRect(x: -1440, y: 874, width: 1440, height: 26)
        let hoverBand = HangerPanel.hoverBand(in: topBand)

        XCTAssertEqual(hoverBand, CGRect(x: -960, y: 874, width: 480, height: 26))
        XCTAssertTrue(NSMouseInRect(CGPoint(x: -720, y: 899), hoverBand, false))
        XCTAssertFalse(NSMouseInRect(CGPoint(x: -961, y: 899), hoverBand, false))
        XCTAssertFalse(NSMouseInRect(CGPoint(x: -480, y: 899), hoverBand, false))
        XCTAssertFalse(NSMouseInRect(CGPoint(x: -720, y: 873), hoverBand, false))
    }
}
