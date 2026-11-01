import AppKit
import Library
import ServiceManagement
import Enrichment
import Overlay
import SwiftUI

/// Preferences that don't belong in the one-click menu. Opening it is the one time Hot Mic
/// deliberately comes to the front.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var extraDAWs = ""
    @State private var rejectedDAWs: [String] = []

    var body: some View {
        TabView {
            LookTab().tabItem { Label("Look", systemImage: "paintpalette") }
            general.tabItem { Label("General", systemImage: "gearshape") }
            sync.tabItem { Label("DAW Sync", systemImage: "metronome") }
        }
        .frame(width: 520, height: 360)
    }

    private var general: some View {
        Form {
            LabeledContent("Takes folder") {
                HStack {
                    Text(model.library.root.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Choose…") { chooseFolder() }
                }
            }
            Text("Put it in iCloud Drive, Dropbox or Google Drive and your takes sync to your other devices.")
                .font(.caption).foregroundStyle(.secondary)
            Stepper("Keep full-session recordings for \(model.retentionDays) days",
                    value: Binding(get: { model.retentionDays }, set: { model.setRetentionDays($0) }), in: 1...365)
            Text("Takes, MIDI and lyrics are kept forever. Only the long whole-session files expire.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Tuned takes", selection: Binding(get: { model.tuneMode }, set: { model.setTuneMode($0) })) {
                Text("Natural (keeps vibrato and slides)").tag(Tuner.Mode.natural)
                Text("Hard snap").tag(Tuner.Mode.hard)
            }
            LabeledContent("Idle pill opacity") {
                Slider(value: Binding(get: { model.overlay.settings.ghostOpacity },
                                      set: { v in model.overlay.update { $0.ghostOpacity = v } }), in: 0.05...0.6)
                    .frame(width: 180)
            }
            Toggle("Show the Hot Mic hub when my DAW opens",
                   isOn: Binding(get: { model.openHubWithDAW }, set: { model.setOpenHubWithDAW($0) }))
            Toggle("Open Hot Mic when I log in", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            Button("Acknowledgements") {
                if let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") { NSWorkspace.shared.open(url) }
            }
        }
        .formStyle(.grouped)
    }

    private var sync: some View {
        Form {
            LabeledContent("Other music apps") {
                TextField("Bundle IDs, comma separated", text: $extraDAWs)
                    .onAppear { extraDAWs = model.extraDAWs.joined(separator: ", ") }
                    .onChange(of: extraDAWs) { _, text in
                        rejectedDAWs = model.setExtraDAWs(text.split(separator: ",").map(String.init))
                    }
                    .frame(width: 260)
            }
            if !rejectedDAWs.isEmpty {
                Text("Not a bundle ID: \(rejectedDAWs.joined(separator: ", "))").font(.caption).foregroundStyle(.red)
            }
            Text("Hot Mic turns on for Live, Logic, GarageBand, FL Studio, Bitwig, REAPER, Cubase and Studio One. Add any other app by its bundle ID (e.g. com.renoise.renoise).")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Time signature", selection: Binding(get: { model.beatsPerBar }, set: { model.setBeatsPerBar($0) })) {
                ForEach([2, 3, 4, 5, 6, 7], id: \.self) { Text("\($0)/4").tag($0) }
            }
            Text("To stamp takes with bars and tempo, send MIDI clock from your DAW to **Hot Mic Sync** once:")
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Self.guides, id: \.0) { daw, steps in
                LabeledContent(daw) { Text(steps).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use this folder"
        if panel.runModal() == .OK, let url = panel.url { model.setLibrary(url) }
    }

    static let guides: [(String, String)] = [
        ("Ableton Live", "Settings → Link, Tempo & MIDI → Output: Hot Mic Sync → Sync on"),
        ("Logic Pro", "File → Project Settings → Synchronization → MIDI → Clock: Hot Mic Sync"),
        ("FL Studio", "Options → MIDI settings → Output: Hot Mic Sync → Send master sync"),
        ("Bitwig Studio", "Settings → Synchronization → MIDI Clock out: Hot Mic Sync"),
        ("REAPER", "Preferences → MIDI Devices → Hot Mic Sync → Send clock / SPP"),
        ("Cubase / Studio One", "Transport / Sync setup → MIDI Clock destination: Hot Mic Sync"),
    ]
}


/// The window's look: style, accent, light or dark. Saved in UserDefaults; the Hot Mic window follows live.
struct LookTab: View {
    @AppStorage(LookPrefs.modeKey) private var mode = "dark"
    @AppStorage(LookPrefs.accentKey) private var accent = "lilac"

    var body: some View {
        Form {
            Picker("Look", selection: $mode) {
                ForEach(LookPrefs.modes, id: \.0) { Text("\($0.1): \($0.2)").tag($0.0) }
            }
            .pickerStyle(.radioGroup)
            Picker("Accent", selection: $accent) {
                ForEach(LookPrefs.accents, id: \.0) { Text($0.1).tag($0.0) }
            }
        }
        .formStyle(.grouped)
        .onChange(of: mode) { _, _ in LookPrefs.changed() }
        .onChange(of: accent) { _, _ in LookPrefs.changed() }
    }
}

enum LookPrefs {
    static let modeKey = "look.mode", accentKey = "look.accent"
    static let didChange = Notification.Name("HotMicLookChanged")
    /// The four looks: id, name, what it is, (style, light?).
    static let modes: [(String, String, String)] = [
        ("vintage", "Vintage", "tube amp hardware, rosewood, glowing screen (dark)"),
        ("light", "Light", "clean and modern, light"),
        ("dark", "Dark", "clean and modern, dark"),
        ("notebook", "Notebook", "your lyrics on real paper"),
    ]
    static let accents: [(String, String)] = [
        ("lilac", "Lilac ice"), ("ice", "Ice"), ("violet", "Violet"), ("periwinkle", "Periwinkle"),
        ("frost", "Frost violet"), ("aurora", "Aurora"), ("dusk", "Dusk"), ("oxblood", "Oxblood"),
        ("ox-ice", "Oxblood + ice"), ("ox-violet", "Oxblood + violet"),
    ]
    static func changed() { NotificationCenter.default.post(name: didChange, object: nil) }
    /// JS that applies the saved look in the Hot Mic window.
    static var script: String {
        let d = UserDefaults.standard
        let mode = d.string(forKey: modeKey) ?? "dark", accent = d.string(forKey: accentKey) ?? "lilac"
        let (style, look): (String, String) = {
            switch mode {
            case "light": return ("modern", "tube-light")
            case "dark": return ("modern", "tube")
            case "notebook": return ("notebook", "tube-light")
            default: return ("vintage", "tube")
            }
        }()
        return "HM.set({style:'\(style)',accent:'\(accent)',look:'\(look)'})"
    }
}
