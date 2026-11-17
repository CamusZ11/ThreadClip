// Rope geometry adapted from Sources/Tendedero/LineView.swift (Alejandro Buján, MIT).
import Foundation
import ThreadHangerCore

struct StripLayout {
    static let cardWidth: CGFloat = 220
    static let cardHeight: CGFloat = 64
    static let cardGap: CGFloat = 18
    static let cardStep = cardWidth + cardGap
    static let panelHeight: CGFloat = 138
    static let ropeTop: CGFloat = 10
    static let pinAbove: CGFloat = 9.5
    static let buttonSize: CGFloat = 28
    private static let buttonEdge: CGFloat = 20
    private static let buttonStep: CGFloat = 36
    private static let buttonClearance = buttonEdge + buttonSize / 2 + 8

    let width: CGFloat
    let cardCount: Int
    let recentCount: Int
    let viewport: CGRect
    let recentViewport: CGRect
    let overflows: Bool

    init(width: CGFloat, cards: [HangerCard]) {
        let currentCount = cards.firstIndex(where: \.isRecent) ?? cards.count
        self.init(width: width, cardCount: currentCount, recentCount: cards.count - currentCount)
    }

    init(width: CGFloat, cardCount: Int, recentCount: Int = 0) {
        self.width = width
        self.cardCount = cardCount
        self.recentCount = recentCount
        let currentWidth = Self.contentWidth(for: cardCount)
        let recentWidth = Self.contentWidth(for: recentCount)
        let initial = Self.viewports(width: width, inset: Self.buttonClearance,
                                     currentWidth: currentWidth, recentWidth: recentWidth)
        let overflows = currentWidth > initial.current.width || recentWidth > initial.recent.width
        self.overflows = overflows
        let final = overflows
            ? Self.viewports(width: width, inset: Self.buttonClearance + Self.buttonStep,
                             currentWidth: currentWidth, recentWidth: recentWidth)
            : initial
        viewport = final.current
        recentViewport = final.recent
    }

    private static func contentWidth(for count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return cardWidth + CGFloat(count - 1) * cardStep
    }

    private static func viewports(width: CGFloat, inset: CGFloat,
                                  currentWidth: CGFloat, recentWidth: CGFloat) -> (current: CGRect, recent: CGRect) {
        func frame(x: CGFloat, width: CGFloat) -> CGRect {
            CGRect(x: x, y: 0, width: width, height: panelHeight)
        }

        let left = min(width / 2, inset)
        let right = width - left
        let available = right - left
        if recentWidth == 0 {
            return (frame(x: left, width: available), frame(x: right, width: 0))
        }
        if currentWidth == 0 {
            let visibleRecent = min(available, recentWidth)
            return (frame(x: left, width: 0), frame(x: right - visibleRecent, width: visibleRecent))
        }

        let gap = min(cardGap, available / 3)
        let cardsWidth = available - gap
        // Reserve room for one recent card, or half the space when the screen is narrow.
        let recentReserve = min(cardWidth, cardsWidth / 2)
        let visibleCurrent = min(currentWidth, cardsWidth - recentReserve)
        let centered = (width - visibleCurrent) / 2
        let currentX = max(left, min(centered, right - recentReserve - gap - visibleCurrent))
        let visibleRecent = min(recentWidth, right - currentX - visibleCurrent - gap)
        return (frame(x: currentX, width: visibleCurrent), frame(x: right - visibleRecent, width: visibleRecent))
    }

    var earlierButtonX: CGFloat { Self.buttonEdge + Self.buttonStep }
    var laterButtonX: CGFloat { collapseButtonX - Self.buttonStep }
    var collapseButtonX: CGFloat { width - Self.buttonEdge }

    var maximumScroll: CGFloat { max(scrollLimit(isRecent: false), scrollLimit(isRecent: true)) }

    func viewport(forRecent isRecent: Bool) -> CGRect { isRecent ? recentViewport : viewport }

    private func scrollLimit(isRecent: Bool) -> CGFloat {
        let content = Self.contentWidth(for: isRecent ? recentCount : cardCount)
        return max(0, content - viewport(forRecent: isRecent).width)
    }

    func clampScroll(_ scroll: CGFloat) -> CGFloat {
        min(maximumScroll, max(0, scroll))
    }

    func cardX(at index: Int, scroll: CGFloat, isRecent: Bool = false) -> CGFloat {
        let viewport = viewport(forRecent: isRecent)
        let content = Self.contentWidth(for: isRecent ? recentCount : cardCount)
        let centering = max(0, viewport.width - content) / 2
        let offset = min(scrollLimit(isRecent: isRecent), max(0, scroll))
        return viewport.minX + centering + Self.cardWidth / 2 + CGFloat(index) * Self.cardStep - offset
    }

    var separatorX: CGFloat? {
        guard cardCount > 0, recentCount > 0, viewport.width > 0, recentViewport.width > 0 else { return nil }
        let gap = min(Self.cardGap, recentViewport.minX - viewport.maxX)
        return recentViewport.minX - gap / 2
    }

    func clipCardHitArea(_ rect: CGRect, isRecent: Bool = false) -> CGRect {
        rect.intersection(viewport(forRecent: isRecent))
    }

    static func sag(width: CGFloat) -> CGFloat { min(30, width * 0.018) }

    func ropeY(at x: CGFloat) -> CGFloat {
        guard width > 0 else { return Self.ropeTop }
        let fraction = min(1, max(0, x / width))
        return Self.ropeTop + 4 * Self.sag(width: width) * fraction * (1 - fraction)
    }
}
