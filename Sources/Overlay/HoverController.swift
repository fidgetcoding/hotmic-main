import Foundation

/// Pure hover logic for the overlay: expand when the mouse touches the hot zone, stay open while
/// it's over the panel, collapse `collapseDelay` after it leaves. No AppKit so it's testable.
public struct HoverController: Sendable {
    public enum State: Equatable, Sendable { case collapsed, expanded }

    public private(set) var state: State = .collapsed
    public var collapseDelay: TimeInterval = 1.0
    private var leaveDeadline: TimeInterval?

    public init() {}

    @discardableResult
    public mutating func update(mouseInHotZone: Bool, mouseInPanel: Bool, now: TimeInterval) -> State {
        switch state {
        case .collapsed:
            if mouseInHotZone { state = .expanded; leaveDeadline = nil }
        case .expanded:
            if mouseInHotZone || mouseInPanel {
                leaveDeadline = nil
            } else if let deadline = leaveDeadline {
                if now >= deadline { state = .collapsed; leaveDeadline = nil }
            } else {
                leaveDeadline = now + collapseDelay
            }
        }
        return state
    }
}

/// How the collapsed pill looks (Nate 2026-09-27: "completely invisible or faintly visible, depends on settings").
public enum IdleMode: String, CaseIterable, Sendable {
    case ghost, invisible
}

public enum PillPosition: String, CaseIterable, Sendable {
    case topCenter, topLeft, topRight, bottomLeft, bottomRight
}

/// Overlay preferences, persisted in UserDefaults.
public struct OverlaySettings: Equatable, Sendable {
    public var idleMode: IdleMode = .ghost
    public var ghostOpacity: Double = 0.15
    public var position: PillPosition = .topCenter
    public var flashOnTake = true

    public init() {}

    public static func load(_ defaults: UserDefaults = .standard) -> OverlaySettings {
        var s = OverlaySettings()
        if let raw = defaults.string(forKey: "overlay.idleMode"), let mode = IdleMode(rawValue: raw) { s.idleMode = mode }
        if defaults.object(forKey: "overlay.ghostOpacity") != nil { s.ghostOpacity = defaults.double(forKey: "overlay.ghostOpacity") }
        if let raw = defaults.string(forKey: "overlay.position"), let p = PillPosition(rawValue: raw) { s.position = p }
        if defaults.object(forKey: "overlay.flashOnTake") != nil { s.flashOnTake = defaults.bool(forKey: "overlay.flashOnTake") }
        return s
    }

    public func save(_ defaults: UserDefaults = .standard) {
        defaults.set(idleMode.rawValue, forKey: "overlay.idleMode")
        defaults.set(ghostOpacity, forKey: "overlay.ghostOpacity")
        defaults.set(position.rawValue, forKey: "overlay.position")
        defaults.set(flashOnTake, forKey: "overlay.flashOnTake")
    }

    /// Pill alpha while collapsed.
    public var idleAlpha: Double { idleMode == .invisible ? 0 : ghostOpacity }
    /// While recording, Ghost mode never drops below this: "is it on?" must be answerable at a glance.
    public var recordingAlpha: Double { idleMode == .invisible ? 0 : max(ghostOpacity, 0.55) }
}
