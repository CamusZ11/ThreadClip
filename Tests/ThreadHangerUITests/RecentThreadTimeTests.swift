import Foundation
import XCTest
@testable import ThreadClip

final class RecentThreadTimeTests: XCTestCase {
    func testUsesWholeMinutesOrLargerUnits() {
        let now = Date(timeIntervalSince1970: 200_000)
        let cases: [(TimeInterval, String)] = [
            (-10, "刚刚"),
            (59, "刚刚"),
            (60, "1 分钟前"),
            (119, "1 分钟前"),
            (14 * 60 + 19, "14 分钟前"),
            (3_599, "59 分钟前"),
            (3_600, "1 小时前"),
            (86_399, "23 小时前"),
            (86_400, "1 天前")
        ]
        for (age, expected) in cases {
            XCTAssertEqual(RecentThreadTime.label(since: now.addingTimeInterval(-age), now: now), expected)
        }
    }
}
