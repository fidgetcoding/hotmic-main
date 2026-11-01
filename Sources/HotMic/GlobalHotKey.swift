import AppKit
import Carbon
import Foundation

/// A system-wide shortcut (Carbon hot keys: no Accessibility permission needed).
final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    /// ⌃⌥H: opens Hot Mic from anywhere, even when the menu bar icon is hidden behind the notch.
    static func openHotMic(_ action: @escaping () -> Void) -> GlobalHotKey {
        GlobalHotKey(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(controlKey | optionKey), action: action)
    }

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let me = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { me.action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x484D_4943), id: 1),  // 'HMIC'
                            GetApplicationEventTarget(), 0, &hotKey)
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

/// The flame-mic menu bar icon (template, so it follows the menu bar's light/dark). A dot = recording.
enum MenuBarIcon {
    static func image(recording: Bool) -> NSImage {
        let name = recording ? "menubar-on" : "menubar-off"
        let image = Bundle.main.url(forResource: name, withExtension: "svg").flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: recording ? "mic.fill" : "mic", accessibilityDescription: "Hot Mic")!
        if image.representations.first is NSImageRep, image.size.height > 19 || image.size.height < 1 {
            image.size = NSSize(width: 18, height: 18)          // SF Symbol fallback
        }                                                     // SVGs carry their own 19 pt-tall size
        image.isTemplate = true
        image.accessibilityDescription = recording ? "Hot Mic, recording" : "Hot Mic"
        return image
    }
}
