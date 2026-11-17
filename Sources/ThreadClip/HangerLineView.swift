// Rope and clothespin adapted from Tendedero's LineView.swift and PeggedView.swift
// (Alejandro Buján, MIT).
import SwiftUI
import ThreadHangerCore

@MainActor
final class HangerPresentation: ObservableObject {
    @Published var isRevealed = false
    @Published var scroll: CGFloat = 0
    var hitRects: [HangerHitTarget: CGRect] = [:]
}

enum HangerHitTarget: Hashable {
    case card(String, isRecent: Bool), earlier, later, collapse
}

private struct HangerHitRects: PreferenceKey {
    static let defaultValue: [HangerHitTarget: CGRect] = [:]

    static func reduce(value: inout [HangerHitTarget: CGRect], nextValue: () -> [HangerHitTarget: CGRect]) {
        value.merge(nextValue()) { _, rect in rect }
    }
}

private let panelSpace = "hangerPanel"

private extension View {
    func reportHitArea(_ target: HangerHitTarget) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: HangerHitRects.self, value: [target: geometry.frame(in: .named(panelSpace))])
            }
        }
    }
}

enum RecentThreadTime {
    static func label(since timestamp: Date, now: Date) -> String {
        let age = now.timeIntervalSince(timestamp)
        switch age {
        case ..<60: return "刚刚"
        case ..<3_600: return "\(Int(age / 60)) 分钟前"
        case ..<86_400: return "\(Int(age / 3_600)) 小时前"
        default: return "\(Int(age / 86_400)) 天前"
        }
    }
}

struct HangerLineView: View {
    @ObservedObject var runtime: HangerRuntime
    @ObservedObject var presentation: HangerPresentation
    let openSettings: (() -> Void)?
    var openCard: (HangerCard) -> Void
    var move: (CGFloat) -> Void
    var collapse: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let layout = StripLayout(width: geometry.size.width, cards: runtime.cards)
            ZStack(alignment: .topLeading) {
                HangerRope(width: layout.width)
                if runtime.cards.isEmpty {
                    Text("暂无 Codex 线程")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .position(x: layout.width / 2, y: layout.ropeY(at: layout.width / 2) + 34)
                        .allowsHitTesting(false)
                }
                cards(layout: layout)
                if layout.overflows {
                    let scroll = layout.clampScroll(presentation.scroll)
                    arrow(towardLater: false, enabled: scroll > 0)
                        .position(x: layout.earlierButtonX, y: 56)
                    arrow(towardLater: true, enabled: scroll < layout.maximumScroll)
                        .position(x: layout.laterButtonX, y: 56)
                }
                control(symbol: "chevron.up", label: "收起线程", target: .collapse, action: collapse)
                    .contextMenu {
                        if let openSettings { Button("悬挂条设置…", action: openSettings) }
                    }
                    .accessibilityActions {
                        if let openSettings { Button("悬挂条设置", action: openSettings) }
                    }
                    .position(x: layout.collapseButtonX, y: 56)
            }
            .frame(width: layout.width, height: StripLayout.panelHeight, alignment: .topLeading)
            .offset(y: presentation.isRevealed ? 0 : -(StripLayout.panelHeight + 12))
            .animation(presentation.isRevealed ? .spring(response: 0.42, dampingFraction: 0.82)
                                               : .easeIn(duration: 0.22), value: presentation.isRevealed)
        }
        .coordinateSpace(name: panelSpace)
        .onPreferenceChange(HangerHitRects.self) { presentation.hitRects = $0 }
    }

    private func cards(layout: StripLayout) -> some View {
        ZStack(alignment: .topLeading) {
            if let x = layout.separatorX {
                Capsule()
                    .fill(Color.primary.opacity(0.22))
                    .frame(width: 1, height: 44)
                    .position(
                        x: x,
                        y: layout.ropeY(at: x) - StripLayout.pinAbove + HangerCardView.height - StripLayout.cardHeight / 2
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if layout.cardCount > 0 {
                let current = runtime.cards.prefix(layout.cardCount)
                let now = Date()
                let expirations = current.compactMap { card -> Date? in
                    guard presentation.isRevealed, card.isUnread, card.status != .waiting else { return nil }
                    let expires = card.highlightStartedAt.addingTimeInterval(runtime.preferences.highlightSeconds)
                    return expires > now ? expires : nil
                }
                TimelineView(.explicit([now] + Set(expirations).sorted())) { context in
                    cardGroup(current, layout: layout, isRecent: false, now: context.date)
                }
            }
            if layout.recentCount > 0 {
                TimelineView(.everyMinute) { context in
                    cardGroup(runtime.cards.suffix(layout.recentCount), layout: layout, isRecent: true, now: context.date)
                }
            }
        }
        .frame(width: layout.width, height: StripLayout.panelHeight, alignment: .topLeading)
        .animation(.spring(response: 0.55, dampingFraction: 0.78), value: runtime.cards.map(\.identity))
    }

    private func cardGroup(_ cards: ArraySlice<HangerCard>, layout: StripLayout, isRecent: Bool, now: Date) -> some View {
        let viewport = layout.viewport(forRecent: isRecent)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(cards.enumerated()), id: \.element.identity) { index, card in
                let x = layout.cardX(at: index, scroll: presentation.scroll, isRecent: isRecent)
                let cardBounds = CGRect(x: x - StripLayout.cardWidth / 2, y: 0,
                                        width: StripLayout.cardWidth, height: StripLayout.panelHeight)
                HangerCardView(
                    card: card,
                    highlighted: card.isHighlighted(until: runtime.preferences.highlightSeconds, now: now),
                    recentTime: isRecent ? RecentThreadTime.label(since: card.changedAt, now: now) : nil,
                    isRevealed: presentation.isRevealed,
                    open: { openCard(card) },
                    markRead: { runtime.markRead(card) }
                )
                .frame(width: StripLayout.cardWidth)
                .position(
                    x: x - viewport.minX,
                    y: layout.ropeY(at: x) - StripLayout.pinAbove + HangerCardView.height / 2
                )
                .accessibilityHidden(!viewport.intersects(cardBounds))
                .transition(.opacity.combined(with: .offset(y: -35)))
            }
        }
        .frame(width: viewport.width, height: StripLayout.panelHeight)
        .contentShape(Rectangle())
        .clipped()
        .offset(x: viewport.minX)
    }

    private func arrow(towardLater: Bool, enabled: Bool) -> some View {
        control(symbol: towardLater ? "chevron.right" : "chevron.left",
                label: towardLater ? "查看较早的线程" : "查看较新的线程",
                target: towardLater ? .later : .earlier,
                enabled: enabled) {
            move(towardLater ? StripLayout.cardStep : -StripLayout.cardStep)
        }
    }

    private func control(symbol: String, label: String, target: HangerHitTarget,
                         enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: StripLayout.buttonSize, height: StripLayout.buttonSize)
                .background(.regularMaterial, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .reportHitArea(target)
    }
}

private struct HangerCardView: View {
    let card: HangerCard
    let highlighted: Bool
    let recentTime: String?
    let isRevealed: Bool
    let open: () -> Void
    let markRead: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var arrived = false
    @State private var swing: Double = 0

    static let height: CGFloat = 26 - 12 + StripLayout.cardHeight

    private var statusAppearance: (label: String, color: Color) {
        if card.isRecent { return ("最近对话", .gray) }
        return switch card.status {
        case .running: ("运行中", .gray)
        case .waiting: ("等待操作", .yellow)
        case .completed: ("已完成", .green)
        case .failed: ("失败", .red)
        case .interrupted: ("已中断", .gray)
        case .unknown: ("状态未知", .gray)
        }
    }

    private var statusColor: Color { card.isUnread ? statusAppearance.color : .gray }
    private var statusTint: Double {
        guard card.isUnread else { return 0 }
        return highlighted ? 0.20 : 0.08
    }

    private var statusIndicator: some View {
        Group {
            if card.status == .running && !card.isRecent {
                let animating = isRevealed && !reduceMotion
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animating)) { context in
                    let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
                    Circle()
                        .trim(from: 0, to: 0.76)
                        .stroke(.gray, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .frame(width: 10, height: 10)
                        .rotationEffect(.degrees(animating ? turn * 360 : -90))
                }
            } else {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
            }
        }
        .frame(width: 7, height: 7)
        .accessibilityHidden(true)
    }

    var body: some View {
        VStack(spacing: -12) {
            HangerClothespin()
                .zIndex(1)
            Button(action: open) {
                HStack(spacing: 10) {
                    statusIndicator
                    VStack(alignment: .leading, spacing: 3) {
                        Text(recentTime ?? card.projectName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(card.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 13)
                .frame(width: StripLayout.cardWidth, height: StripLayout.cardHeight)
                .background(.regularMaterial, in: cardShape)
                .background {
                    cardShape.fill(.background)
                }
                .overlay {
                    cardShape.fill(statusColor.opacity(statusTint))
                        .allowsHitTesting(false)
                }
                .overlay {
                    cardShape.strokeBorder(highlighted ? statusColor.opacity(0.80) : Color.primary.opacity(hovered ? 0.25 : 0.12),
                                           lineWidth: highlighted ? 1.2 : 0.75)
                        .allowsHitTesting(false)
                }
                .contentShape(cardShape)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(card.projectName)，\(card.title)")
            .accessibilityValue(card.isUnread ? "\(statusAppearance.label)，未读" : statusAppearance.label)
            .accessibilityHint("在 Codex 中打开")
            .help("\(card.projectName) · \(card.title)\n\(statusAppearance.label)")
            .contextMenu {
                if card.isUnread { Button("标为已读", action: markRead) }
            }
            .shadow(color: .black.opacity(hovered ? 0.24 : 0.16), radius: hovered ? 11 : 8, y: 4)
            .reportHitArea(.card(card.identity, isRecent: card.isRecent))
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.15), value: hovered)
            .animation(.easeOut(duration: 0.20), value: highlighted)
        }
        .rotationEffect(.degrees(swing), anchor: .top)
        .offset(y: arrived ? 0 : -35)
        .opacity(arrived ? 1 : 0)
        .onAppear {
            guard !reduceMotion else { arrived = true; return }
            swing = 12
            withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) { arrived = true }
            withAnimation(.interpolatingSpring(stiffness: 46, damping: 2.6)) { swing = 0 }
        }
    }

    private var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: 11, style: .continuous) }
}

private struct HangerRope: View {
    let width: CGFloat

    private var path: Path {
        Path { path in
            let top = StripLayout.ropeTop
            path.move(to: CGPoint(x: 0, y: top))
            path.addQuadCurve(to: CGPoint(x: width, y: top),
                              control: CGPoint(x: width / 2, y: top + 2 * StripLayout.sag(width: width)))
        }
    }

    var body: some View {
        ZStack {
            path.stroke(Color.black.opacity(0.22), lineWidth: 1.4).offset(y: 1.2).blur(radius: 1.2)
            path.stroke(Color(white: 0.55), lineWidth: 1.2)
            path.stroke(Color.white.opacity(0.45), lineWidth: 0.4).offset(y: -0.35)
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.08),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        )
        .allowsHitTesting(false)
    }
}

private struct HangerClothespin: View {
    private let metal = LinearGradient(stops: [
        .init(color: Color(white: 0.70), location: 0),
        .init(color: Color(white: 0.93), location: 0.35),
        .init(color: Color(white: 0.82), location: 0.65),
        .init(color: Color(white: 0.62), location: 1),
    ], startPoint: .leading, endPoint: .trailing)

    var body: some View {
        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            .fill(metal)
            .frame(width: 9, height: 26)
            .overlay {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .stroke(LinearGradient(colors: [Color.white.opacity(0.9), Color.black.opacity(0.18)],
                                           startPoint: .top, endPoint: .bottom), lineWidth: 0.6)
            }
            .overlay(alignment: .top) {
                Capsule()
                    .fill(Color.black.opacity(0.32))
                    .frame(width: 5, height: 1.4)
                    .padding(.top, 8.5)
            }
            .shadow(color: .black.opacity(0.30), radius: 2, y: 1.5)
            .allowsHitTesting(false)
    }
}
