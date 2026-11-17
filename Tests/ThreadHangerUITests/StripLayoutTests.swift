import XCTest
@testable import ThreadClip

final class StripLayoutTests: XCTestCase {
    func testSingleCardIsCenteredOnTheScreen() {
        let layout = StripLayout(width: 800, cardCount: 1)

        XCTAssertEqual(layout.cardX(at: 0, scroll: 0), 400)
    }

    func testShortLineCentersTheGroupWithoutScrolling() {
        let layout = StripLayout(width: 800, cardCount: 2)

        XCTAssertFalse(layout.overflows)
        let firstX = layout.cardX(at: 0, scroll: 0)
        let lastX = layout.cardX(at: 1, scroll: 0)
        XCTAssertEqual((firstX + lastX) / 2, 400)
        XCTAssertEqual(lastX - firstX, StripLayout.cardWidth + StripLayout.cardGap)
        XCTAssertEqual(layout.clampScroll(999), 0)
    }

    func testCurrentGroupStaysCenteredAndRecentCardEndsAtTheRightInset() {
        let layout = StripLayout(width: 1100, cardCount: 2, recentCount: 1)

        XCTAssertFalse(layout.overflows)
        XCTAssertEqual((layout.cardX(at: 0, scroll: 0) + layout.cardX(at: 1, scroll: 0)) / 2, 550)
        XCTAssertEqual(layout.cardX(at: 0, scroll: 0, isRecent: true) + StripLayout.cardWidth / 2, 1058)
        XCTAssertEqual(layout.separatorX, layout.recentViewport.minX - StripLayout.cardGap / 2)
        XCTAssertLessThan(layout.viewport.maxX, layout.recentViewport.minX)
    }

    func testRecentOnlyGroupIsRightAlignedWithoutASeparator() {
        let layout = StripLayout(width: 800, cardCount: 0, recentCount: 2)

        XCTAssertFalse(layout.overflows)
        XCTAssertNil(layout.separatorX)
        XCTAssertEqual(layout.cardX(at: 1, scroll: 0, isRecent: true) + StripLayout.cardWidth / 2, 758)
        XCTAssertNil(StripLayout(width: 800, cardCount: 2).separatorX)
    }

    func testWideScreenKeepsActiveCardCenteredWhileRecentCardsScroll() {
        let layout = StripLayout(width: 1920, cardCount: 1, recentCount: 5)

        XCTAssertTrue(layout.overflows)
        XCTAssertEqual(layout.cardX(at: 0, scroll: 0), 960)
        XCTAssertEqual(layout.cardX(at: 0, scroll: layout.maximumScroll), 960)
        XCTAssertEqual(layout.cardX(at: 0, scroll: 0, isRecent: true) - StripLayout.cardWidth / 2, layout.recentViewport.minX)
        XCTAssertEqual(layout.cardX(at: 4, scroll: layout.maximumScroll, isRecent: true) + StripLayout.cardWidth / 2,
                       layout.recentViewport.maxX)
    }

    func testNarrowMixedGroupsKeepSeparateHitAreasAndCanReachTheLastCardInEach() {
        let layout = StripLayout(width: 420, cardCount: 4, recentCount: 2)

        XCTAssertGreaterThan(layout.viewport.width, 0)
        XCTAssertGreaterThan(layout.recentViewport.width, 0)
        XCTAssertLessThan(layout.viewport.maxX, layout.recentViewport.minX)
        XCTAssertTrue(layout.clipCardHitArea(layout.recentViewport).isNull)
        XCTAssertTrue(layout.clipCardHitArea(layout.viewport, isRecent: true).isNull)
        XCTAssertEqual(layout.cardX(at: 3, scroll: layout.maximumScroll) + StripLayout.cardWidth / 2, layout.viewport.maxX)
        XCTAssertEqual(layout.cardX(at: 1, scroll: layout.maximumScroll, isRecent: true) + StripLayout.cardWidth / 2,
                       layout.recentViewport.maxX)
    }

    func testOverflowLeavesRoomForArrowsAndShowsLastCardAtMaximumScroll() {
        let layout = StripLayout(width: 800, cardCount: 6)

        XCTAssertTrue(layout.overflows)
        XCTAssertGreaterThan(layout.viewport.minX, 20)
        XCTAssertLessThan(layout.viewport.maxX, 780)
        XCTAssertEqual(layout.clampScroll(-10), 0)
        XCTAssertGreaterThan(layout.maximumScroll, 0)
        XCTAssertEqual(layout.viewport.midX, 400)
        XCTAssertEqual((layout.earlierButtonX + layout.laterButtonX) / 2, 400)
        XCTAssertEqual(layout.cardX(at: 0, scroll: 0) - StripLayout.cardWidth / 2, layout.viewport.minX)
        let lastX = layout.cardX(at: 5, scroll: layout.clampScroll(10_000))
        XCTAssertEqual(lastX + StripLayout.cardWidth / 2, layout.viewport.maxX, accuracy: 0.001)
    }

    func testCardHitAreaIsClippedToTheViewport() {
        let layout = StripLayout(width: 800, cardCount: 6)
        let outside = CGRect(x: 0, y: 27, width: 20, height: 60)
        let partial = CGRect(x: layout.viewport.minX - 10, y: 27, width: 220, height: 60)

        XCTAssertTrue(layout.clipCardHitArea(outside).isNull)
        let clipped = layout.clipCardHitArea(partial)
        XCTAssertEqual(clipped.minX, layout.viewport.minX)
        XCTAssertEqual(clipped.width, 210)
    }

    func testCloseControlHasDedicatedRoomForAFittingLine() {
        let layout = StripLayout(width: 550, cardCount: 2)

        XCTAssertFalse(layout.overflows)
        XCTAssertLessThanOrEqual(layout.viewport.maxX, layout.collapseButtonX - StripLayout.buttonSize / 2)
    }

    func testOverflowLeavesRoomForBothRightEdgeControls() {
        let layout = StripLayout(width: 800, cardCount: 6)

        XCTAssertTrue(layout.overflows)
        XCTAssertLessThanOrEqual(layout.viewport.maxX, layout.laterButtonX - StripLayout.buttonSize / 2)
        XCTAssertGreaterThanOrEqual(layout.viewport.minX, layout.earlierButtonX + StripLayout.buttonSize / 2)
        XCTAssertGreaterThanOrEqual(layout.collapseButtonX - layout.laterButtonX, StripLayout.buttonSize)
    }

    func testEmptyLineCanStillPlaceTheCloseControlAtTheRightEdge() {
        let layout = StripLayout(width: 800, cardCount: 0)

        XCTAssertFalse(layout.overflows)
        XCTAssertGreaterThan(layout.collapseButtonX, layout.width / 2)
        XCTAssertLessThanOrEqual(layout.collapseButtonX + StripLayout.buttonSize / 2, layout.width)
    }

    func testNarrowScreenKeepsOverflowControlsClearOfCards() {
        let layout = StripLayout(width: 320, cardCount: 2)

        XCTAssertTrue(layout.overflows)
        XCTAssertGreaterThan(layout.viewport.width, 0)
        XCTAssertEqual(layout.viewport.midX, 160)
        XCTAssertGreaterThanOrEqual(layout.viewport.minX, layout.earlierButtonX + StripLayout.buttonSize / 2)
        XCTAssertLessThanOrEqual(layout.viewport.maxX, layout.laterButtonX - StripLayout.buttonSize / 2)
        XCTAssertGreaterThanOrEqual(layout.collapseButtonX - layout.laterButtonX, StripLayout.buttonSize)
    }
}
