import AppKit
import Combine
import SwiftUI

/// Floating panel that can never become key or main, so it never takes focus or keystrokes from the DAW.
public final class OverlayPanel: NSPanel {
    public init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}

/// Owns the recording pill: shown only while a session records and the Hot Mic window isn't in
/// front (so you can see it's still going from any app). Click it to bring the window back.
public final class OverlayController {
    public let panel = OverlayPanel()
    private let state: OverlayState
    private var hover = HoverController()
    private var timer: Timer?
    private var hosting: NSHostingView<OverlayView>?
    private var flashUntil: Date?
    /// Full-strength "REC · Ableton Live" for a few seconds whenever a session starts.
    private var announceUntil: Date?
    private var subscriptions: Set<AnyCancellable> = []

    static let idlePillSize = NSSize(width: 120, height: 10)
    static let recordingPillSize = NSSize(width: 190, height: 24)
    var pillSize: NSSize { state.isOn ? Self.recordingPillSize : Self.idlePillSize }
    static let hotZoneSlop: CGFloat = 24
    /// True while the Hot Mic window is the key window: the pill hides (the window shows recording).
    public var appWindowFront: () -> Bool = { false }
    private var shown = false

    public init(state: OverlayState) {
        self.state = state
        state.$pulse.dropFirst().sink { [weak self] _ in self?.flash() }.store(in: &subscriptions)
        state.$settings.sink { [weak self] _ in DispatchQueue.main.async { self?.render() } }.store(in: &subscriptions)
        state.$isOn.removeDuplicates().sink { [weak self] on in
            DispatchQueue.main.async {
                guard let self else { return }
                self.announceUntil = on ? Date().addingTimeInterval(8) : nil
                self.render()
            }
        }.store(in: &subscriptions)
        state.$stopping.removeDuplicates().sink { [weak self] _ in DispatchQueue.main.async { self?.render() } }.store(in: &subscriptions)
    }

    public func start() {
        render()
        panel.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
    }

    public func stop() {
        timer?.invalidate()
        panel.orderOut(nil)
    }

    private var screen: NSScreen {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func tick() {
        if shouldShow != shown { render() }
        if let until = flashUntil, Date() >= until { flashUntil = nil; render() }
        if let until = announceUntil, Date() >= until { announceUntil = nil; render() }
    }

    private func flash() {
        guard state.settings.flashOnTake else { return }
        flashUntil = Date().addingTimeInterval(1.2)
        render()
    }

    /// Screen-edge hot zone around the pill; reaches the edge so Invisible mode is still findable.
    func hotZone() -> NSRect {
        let pill = pillFrame(on: screen)
        let visible = screen.frame
        var zone = pill.insetBy(dx: -Self.hotZoneSlop, dy: -Self.hotZoneSlop / 2)
        switch state.settings.position {
        case .topCenter, .topLeft, .topRight: zone.size.height = visible.maxY - zone.minY
        case .bottomLeft, .bottomRight: zone.size.height += zone.minY - visible.minY; zone.origin.y = visible.minY
        }
        return zone
    }

    func pillFrame(on screen: NSScreen) -> NSRect {
        let v = screen.visibleFrame, s = pillSize, margin: CGFloat = 6
        switch state.settings.position {
        case .topCenter: return NSRect(x: v.midX - s.width / 2, y: v.maxY - s.height - margin, width: s.width, height: s.height)
        case .topLeft: return NSRect(x: v.minX + margin, y: v.maxY - s.height - margin, width: s.width, height: s.height)
        case .topRight: return NSRect(x: v.maxX - s.width - margin, y: v.maxY - s.height - margin, width: s.width, height: s.height)
        case .bottomLeft: return NSRect(x: v.minX + margin, y: v.minY + margin, width: s.width, height: s.height)
        case .bottomRight: return NSRect(x: v.maxX - s.width - margin, y: v.minY + margin, width: s.width, height: s.height)
        }
    }

    private var shouldShow: Bool { (state.isOn || state.stopping) && !appWindowFront() }

    private func render() {
        shown = shouldShow
        let expanded = false                           // the old quick panel is retired: the window does that now
        let view = OverlayView(state: state, expanded: expanded)
        if let hosting { hosting.rootView = view } else {
            let h = NSHostingView(rootView: view)
            panel.contentView = h
            hosting = h
        }
        let pill = pillFrame(on: screen)
        let size = expanded ? (hosting?.fittingSize ?? NSSize(width: 320, height: 160)) : pillSize
        let top = state.settings.position == .bottomLeft || state.settings.position == .bottomRight
            ? pill.minY + size.height : pill.maxY
        let x: CGFloat
        switch state.settings.position {
        case .topCenter: x = pill.midX - size.width / 2
        case .topLeft, .bottomLeft: x = pill.minX
        case .topRight, .bottomRight: x = pill.maxX - size.width
        }
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)

        panel.ignoresMouseEvents = !shown              // clickable only while it's up
        let alpha: Double
        if !shown { alpha = 0 }
        else if announceUntil != nil || state.stopping || flashUntil != nil { alpha = 1 }
        else { alpha = max(0.75, state.settings.recordingAlpha) }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = alpha
        }
    }
}
