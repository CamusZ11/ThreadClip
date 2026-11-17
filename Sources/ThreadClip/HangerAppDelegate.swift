// Nonactivating presentation, hover and Space recovery adapted from
// Sources/Tendedero/AppDelegate.swift (Alejandro Buján, MIT).
import AppKit
import Combine
import SwiftUI
import ThreadHangerCore

@MainActor
final class HangerAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let runtime: HangerRuntime
    private let presentation = HangerPresentation()
    private let showsStatusItem = HangerAppDelegate.showsStatusItem(bundleURL: Bundle.main.bundleURL)
    private var panel: HangerPanel?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var mouseTimer: Timer?
    private var cardChanges: AnyCancellable?
    private var eventMonitors: [Any] = []
    private var hoverStartedAt: Date?
    private var suppressedUntilPointerLeaves = false
    private var openedManually = false
    private var menuTrackingDepth = 0
    private var escapeCaptureRequested = false
    private var escapeHotKey: HangerEscapeHotKey?
    private var presentationGeneration = 0

    init(runtime: HangerRuntime) {
        self.runtime = runtime
        super.init()
    }

    static func showsStatusItem(bundleURL: URL) -> Bool {
        !bundleURL.resolvingSymlinksInPath().deletingLastPathComponent()
            .pathComponents.contains(where: { $0.hasSuffix(".app") })
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let line = HangerLineView(
            runtime: runtime,
            presentation: presentation,
            openSettings: showsStatusItem ? nil : { [weak self] in self?.openSettings() }
        ) { [weak self] card in
            self?.openCard(card)
        } move: { [weak self] delta in
            self?.moveScroll(by: delta)
        } collapse: { [weak self] in
            self?.hide(suppressHover: true)
        }
        let content = HangerHostingView(rootView: line)
        panel = makePanel(content: content)
        if showsStatusItem { configureMenu() }
        observeMenuBarClicks()

        let notifications = NotificationCenter.default
        notifications.addObserver(self, selector: #selector(screenConfigurationChanged),
                                  name: NSApplication.didChangeScreenParametersNotification, object: nil)
        notifications.addObserver(self, selector: #selector(menuTrackingBegan),
                                  name: NSMenu.didBeginTrackingNotification, object: nil)
        notifications.addObserver(self, selector: #selector(menuTrackingEnded),
                                  name: NSMenu.didEndTrackingNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screenConfigurationChanged),
                                                           name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        cardChanges = runtime.$cards.sink { [weak self] cards in
            guard let self else { return }
            if self.runtime.cards.contains(where: \.isUnread), !cards.contains(where: \.isUnread) {
                self.openedManually = false
            }
            self.updateMouseTracking(hasCards: !cards.isEmpty)
        }

        runtime.onAutoReveal = { [weak self] in self?.automaticallyReveal() }
        runtime.start()
        if ProcessInfo.processInfo.arguments.contains("--reveal") { revealManually() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateEscapeCapture(false)
        runtime.onAutoReveal = nil
        runtime.stop()
        mouseTimer?.invalidate()
        eventMonitors.forEach(NSEvent.removeMonitor)
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        _ = revealFromRunningInstance()
        return false
    }

    func revealFromRunningInstance() -> Bool {
        guard panel != nil else { return false }
        revealManually()
        return true
    }

    private func makePanel(content: NSView) -> HangerPanel {
        let panel = HangerPanel(content: content)
        panel.onScroll = { [weak self] event in
            let horizontal = event.scrollingDeltaX
            let shiftedVertical = event.modifierFlags.contains(.shift) ? event.scrollingDeltaY : 0
            let delta = horizontal == 0 ? shiftedVertical : horizontal
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            self?.moveScroll(by: -delta * scale)
        }
        return panel
    }

    @objc private func screenConfigurationChanged() {
        updateEscapeCapture(false)
        guard let screen = HangerPanel.primaryScreen else {
            hide()
            return
        }
        panel?.place(on: screen)
        clampScroll()
        if presentation.isRevealed { keepOnActiveSpace() }
    }

    @objc private func menuTrackingBegan() {
        menuTrackingDepth += 1
        updateEscapeCapture(false)
    }
    @objc private func menuTrackingEnded() { menuTrackingDepth = max(0, menuTrackingDepth - 1) }

    private func keepOnActiveSpace() {
        guard presentation.isRevealed, let old = panel, old.isVisible, !old.isOnActiveSpace,
              let content = old.contentView else { return }
        old.contentView = NSView()
        old.orderOut(nil)
        let fresh = makePanel(content: content)
        fresh.setFrame(old.frame, display: false)
        panel = fresh
        fresh.orderFrontRegardless()
    }

    private func automaticallyReveal() {
        guard !runtime.preferences.isPaused else { return }
        presentation.scroll = 0
        if runtime.cards.contains(where: \.isUnread) || pointerIsAtStrip {
            show()
        } else if !openedManually {
            hide()
        }
    }

    private var pointerIsAtStrip: Bool {
        guard let screen = HangerPanel.primaryScreen else { return false }
        let mouse = NSEvent.mouseLocation
        return NSMouseInRect(mouse, HangerPanel.hoverBand(in: HangerPanel.menuBarBand(of: screen)), false)
            || (presentation.isRevealed && panel?.frame.contains(mouse) == true)
    }

    private func revealManually() {
        openedManually = true
        show()
    }

    private func show() {
        guard let panel, let screen = HangerPanel.primaryScreen else { return }
        panel.place(on: screen)
        guard !presentation.isRevealed else { return }
        presentationGeneration += 1
        presentation.scroll = 0
        hoverStartedAt = nil
        panel.orderFrontRegardless()
        presentation.isRevealed = true
        updateMouseTracking(hasCards: !runtime.cards.isEmpty)
        DispatchQueue.main.async { [weak self] in self?.keepOnActiveSpace() }
    }

    private func openCard(_ card: HangerCard) {
        let generation = presentationGeneration
        runtime.open(card) { [weak self] in
            guard let self, self.presentationGeneration == generation else { return }
            self.hide(suppressHover: true)
        }
    }

    private func hide(suppressHover: Bool = false) {
        if suppressHover { suppressedUntilPointerLeaves = true }
        openedManually = false
        hoverStartedAt = nil
        updateEscapeCapture(false)
        guard presentation.isRevealed else { return }
        presentationGeneration += 1
        let generation = presentationGeneration
        presentation.isRevealed = false
        panel?.ignoresMouseEvents = true
        presentation.hitRects = [:]
        updateMouseTracking(hasCards: !runtime.cards.isEmpty)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.presentationGeneration == generation else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func updateMouseTracking(hasCards: Bool) {
        guard hasCards || presentation.isRevealed else {
            mouseTimer?.invalidate()
            mouseTimer = nil
            suppressedUntilPointerLeaves = false
            return
        }
        guard mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func tick() {
        guard let panel, let screen = HangerPanel.primaryScreen else {
            updateEscapeCapture(false)
            return
        }
        let mouse = NSEvent.mouseLocation
        let menuBar = HangerPanel.menuBarBand(of: screen)
        let inHoverBand = NSMouseInRect(mouse, HangerPanel.hoverBand(in: menuBar), false)
        if !inHoverBand { suppressedUntilPointerLeaves = false }
        updateEscapeCapture(shouldCaptureEscape(at: mouse))

        if !presentation.isRevealed {
            guard inHoverBand, !suppressedUntilPointerLeaves, menuTrackingDepth == 0, !runtime.cards.isEmpty else {
                hoverStartedAt = nil
                return
            }
            let now = Date()
            let started = hoverStartedAt ?? now
            hoverStartedAt = started
            if now.timeIntervalSince(started) >= 0.25 { show() }
            return
        }

        clampScroll()
        let inside = inHoverBand || panel.frame.contains(mouse)
        if inside { openedManually = false }
        if !inside, !openedManually, menuTrackingDepth == 0,
           runtime.preferences.isPaused || !runtime.cards.contains(where: \.isUnread) {
            hide()
            return
        }

        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        let layout = StripLayout(width: panel.frame.width, cards: runtime.cards)
        let hasControl = !NSMouseInRect(mouse, menuBar, false) && presentation.hitRects.contains { target, rect in
            switch target {
            case let .card(_, isRecent): layout.clipCardHitArea(rect, isRecent: isRecent).contains(flipped)
            case .earlier, .later, .collapse: rect.contains(flipped)
            }
        }
        if panel.ignoresMouseEvents == hasControl { panel.ignoresMouseEvents = !hasControl }
    }

    private func shouldCaptureEscape(at mouse: NSPoint) -> Bool {
        guard presentation.isRevealed, menuTrackingDepth == 0, let panel, panel.isVisible else { return false }
        return panel.frame.contains(mouse)
    }

    private func updateEscapeCapture(_ requested: Bool) {
        guard requested != escapeCaptureRequested else { return }
        escapeCaptureRequested = requested
        if requested {
            escapeHotKey = HangerEscapeHotKey { [weak self] in
                guard let self, self.shouldCaptureEscape(at: NSEvent.mouseLocation) else { return false }
                self.hide(suppressHover: true)
                return true
            }
        } else {
            escapeHotKey = nil
        }
    }

    private func observeMenuBarClicks() {
        let dismissOnMenuBarClick: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                let mouse = NSEvent.mouseLocation
                guard let self, let screen = HangerPanel.primaryScreen,
                      NSMouseInRect(mouse, HangerPanel.menuBarBand(of: screen), false),
                      self.statusItem?.button?.window?.frame.contains(mouse) != true else { return }
                self.hide(suppressHover: true)
            }
        }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: dismissOnMenuBarClick) {
            eventMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { event in
            dismissOnMenuBarClick(event)
            return event
        }) { eventMonitors.append(local) }
    }

    private func clampScroll() { moveScroll(by: 0) }

    private func moveScroll(by delta: CGFloat) {
        guard let panel else { return }
        let layout = StripLayout(width: panel.frame.width, cards: runtime.cards)
        let position = layout.clampScroll(presentation.scroll + delta)
        if position != presentation.scroll { presentation.scroll = position }
    }

    private func configureMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled",
                            accessibilityDescription: "ThreadClip")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "ThreadClip"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addMenuItem(presentation.isRevealed ? "收起线程" : "展开线程",
                    action: #selector(toggleLine), to: menu)
        addMenuItem(runtime.preferences.isPaused ? "恢复自动弹出" : "暂停自动弹出",
                    action: #selector(togglePause), to: menu)
        menu.addItem(.separator())
        addMenuItem("设置…", action: #selector(openSettings), key: ",", to: menu)
        addMenuItem("退出 ThreadClip", action: #selector(quit), key: "q", to: menu)
    }

    private func addMenuItem(_ title: String, action: Selector, key: String = "", to menu: NSMenu) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
    }

    @objc private func toggleLine() {
        if presentation.isRevealed { hide(suppressHover: true) } else { revealManually() }
    }

    @objc private func togglePause() { runtime.setPaused(!runtime.preferences.isPaused) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let allowsLoginItem = showsStatusItem && Bundle.main.bundleURL.pathExtension == "app"
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 460, height: 335),
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "ThreadClip 设置"
            window.contentView = NSHostingView(rootView: HangerSettingsView(runtime: runtime, allowsLoginItem: allowsLoginItem))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
