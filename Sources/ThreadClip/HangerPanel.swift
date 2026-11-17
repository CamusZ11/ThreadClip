// Adapted from Sources/Tendedero/LinePanel.swift (Alejandro Buján, MIT).
import AppKit
import Carbon
import SwiftUI

@MainActor
final class HangerPanel: NSPanel {
    var onScroll: ((NSEvent) -> Void)?

    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, let onScroll {
            onScroll(event)
        } else {
            super.sendEvent(event)
        }
    }

    static var primaryScreen: NSScreen? {
        let displayID = CGMainDisplayID()
        let screenNumber = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.first { ($0.deviceDescription[screenNumber] as? NSNumber)?.uint32Value == displayID }
    }

    static func menuBarBand(of screen: NSScreen) -> CGRect {
        let reservedHeight = screen.frame.maxY - screen.visibleFrame.maxY
        let height = reservedHeight >= 1 ? reservedHeight : max(NSStatusBar.system.thickness, screen.safeAreaInsets.top)
        return CGRect(x: screen.frame.minX, y: screen.frame.maxY - height,
                      width: screen.frame.width, height: height)
    }

    static func hoverBand(in menuBar: CGRect) -> CGRect {
        let third = menuBar.width / 3
        return CGRect(x: menuBar.minX + third, y: menuBar.minY, width: third, height: menuBar.height)
    }

    func place(on screen: NSScreen) {
        let top = Self.menuBarBand(of: screen).minY
        let target = CGRect(x: screen.frame.minX, y: top - StripLayout.panelHeight,
                            width: screen.frame.width, height: StripLayout.panelHeight)
        if frame != target { setFrame(target, display: true) }
    }
}

final class HangerHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// Permission-free hot key registration adapted from Sources/Tendedero/HotKey.swift.
final class HangerEscapeHotKey {
    private static let signature: OSType = 0x4348_4E47 // CHNG
    private var handler: EventHandlerRef?
    private var key: EventHotKeyRef?
    private let action: @MainActor () -> Bool

    init?(action: @escaping @MainActor () -> Bool) {
        self.action = action
        let target = GetApplicationEventTarget()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(target, { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard status == noErr, pressed.signature == HangerEscapeHotKey.signature, pressed.id == 1 else {
                return OSStatus(eventNotHandledErr)
            }
            let shortcut = Unmanaged<HangerEscapeHotKey>.fromOpaque(context).takeUnretainedValue()
            return MainActor.assumeIsolated { shortcut.action() ? noErr : OSStatus(eventNotHandledErr) }
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard handlerStatus == noErr, handler != nil else { return nil }

        let id = EventHotKeyID(signature: Self.signature, id: 1)
        guard RegisterEventHotKey(UInt32(kVK_Escape), 0, id, target, 0, &key) == noErr, key != nil else {
            return nil
        }
    }

    deinit {
        if let key { UnregisterEventHotKey(key) }
        if let handler { RemoveEventHandler(handler) }
    }
}
