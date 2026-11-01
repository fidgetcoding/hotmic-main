import AppKit
import Combine
import Capture
import CoreAudio
import Library
import MediaScheme
import UniformTypeIdentifiers
import WebKit

/// The Hot Mic window: the designed UI (bundled `ui/`, the design lab) in a web view, fed with the
/// real library and wired to the real recorder. Replaces the SwiftUI hub (still under "Classic hub").
@MainActor
final class LabWindowController: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    private(set) var window: NSWindow?
    private var web: DragWebView?
    private weak var model: AppModel?
    private var library: () -> LibraryLocation
    private var current: URL?
    private var ready = false
    private var settingsPending = false
    private var refreshPending = false
    private var lookObserver: NSObjectProtocol?
    private var bag = Set<AnyCancellable>()

    init(model: AppModel, library: @escaping () -> LibraryLocation) {
        self.model = model
        self.library = library
        super.init()
        model.$armedBy.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] armed in
            Task { @MainActor in self?.recordingChanged(armed != nil) }
        }.store(in: &bag)
    }

    var isVisible: Bool { window?.isVisible == true }

    func show(activate: Bool) {
        if window == nil { build() }
        // A clean slate every time the window opens; a running recording shows instead.
        current = model?.currentRecordingFolder
        if ready { js("HM.host.fresh()") }
        if activate { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) } else { window?.orderFrontRegardless() }
        if let web { window?.makeFirstResponder(web) }       // keys (R, Space, ⌫…) reach the page
        if ready { pushAll() }
    }

    private func build() {
        let config = WKWebViewConfiguration()
        let content = WKUserContentController()
        content.addUserScript(WKUserScript(source: "window.HM_HOST = true;", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.add(WeakHandler(self), name: "hotmic")
        config.userContentController = content
        config.setURLSchemeHandler(LibraryMediaSchemeHandler { [weak self] in self?.library().root },
                                   forURLScheme: LibraryMedia.scheme)
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = DragWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.onImport = { [weak self] urls in self?.model?.importRecordings(urls) }
        web.onImportHover = { [weak self] on in
            self?.js("document.getElementById('win')?.classList.toggle('drop-on', \(on)); document.getElementById('win')?.classList.toggle('drop-import', \(on))")
        }
        web.setValue(false, forKey: "drawsBackground")
        self.web = web

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Hot Mic"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar()              // a 52 pt title bar, so the traffic lights sit in the Tube Amp bar
        window.toolbarStyle = .unifiedCompact
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1000, height: 640)
        window.backgroundColor = NSColor(red: 0.07, green: 0.06, blue: 0.05, alpha: 1)
        window.contentView = web
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("HotMicWindow")
        self.window = window
        web.window?.makeFirstResponder(web)

        guard let ui = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "ui") else {
            web.loadHTMLString("<body style='background:#120f0c;color:#eee;font:15px -apple-system;padding:40px'>The Hot Mic UI is missing from the app bundle (ui/index.html). Rebuild with scripts/install.sh.</body>", baseURL: nil)
            return
        }
        // The page reads only its own folder. Takes in your library play through hotmic-media:// (MediaScheme),
        // which serves nothing outside the library.
        web.loadFileURL(ui, allowingReadAccessTo: ui.deletingLastPathComponent())
        placeTrafficLights()
    }

    // MARK: - pushing state to the page

    /// Settings… (⌘,): the look is picked in the window's Settings popover.
    func openSettings() {
        if ready { js("HM.openSettings()") } else { settingsPending = true }
    }

    private func js(_ script: String) { web?.evaluateJavaScript(script, completionHandler: nil) }

    private func pushAll() {
        let lib = library()
        let index = LibraryIndex(location: lib)
        Task { [weak self] in
            let list = await Task.detached(priority: .userInitiated) { LabSessionExport.list(index) }.value
            guard let self else { return }
            if let c = self.current, !FileManager.default.fileExists(atPath: c.path) { self.current = nil }
            // Nothing picked and not recording: the empty session ("Ready when you are").
            if self.current == nil { self.current = self.model?.currentRecordingFolder }
            self.js("HM.host.sessions(\(LabSessionExport.json(list)))")
            self.pushMics()
            self.pushRecording()
            self.pushSession()
        }
    }

    private func pushSession() {
        guard let folder = current else { js("HM.host.load({id:'',name:'New session',folder:'',length:0,takes:[],slots:[]})"); return }
        Task { [weak self] in
            let json = await Task.detached(priority: .userInitiated) { LabSessionExport.json(LabSessionExport.session(folder: folder)) }.value
            self?.js("HM.host.load(\(json))")
        }
    }

    /// Words as you sing them (partial results), and the one-line notice when live words are off.
    /// Self-test only: show the window as if recording, so live words draw the way they do in a session.
    /// Diagnostics only (`--ui-js`): run a line of page script once the window is up.
    func debugJS(_ script: String) { js(script) }

    func selftestRecording(_ on: Bool) { js("HM.S.growing = \(on); HM.render && HM.render()") }

    func live(_ text: String, final: Bool) {
        guard ready else { return }
        js("HM.host.live({text: \(LabSessionExport.json(text)), final: \(final)})")
    }
    func liveNotice(_ notice: String?) {
        guard ready else { return }
        js("HM.host.liveNotice(\(notice.map { LabSessionExport.json($0) } ?? "null"))")
    }
    /// A line just finished: the page shows it as a row at once (the saved session follows half a second later).
    func lineDone(_ text: String, at: Double, end: Double) {
        guard ready else { return }
        js("HM.host.lineDone({text: \(LabSessionExport.json(text)), at: \(String(format: "%.3f", at)), end: \(String(format: "%.3f", end))})")
    }

    // MARK: - deleting sessions (sidebar, like Notes: to the Trash, with Undo)

    /// What the last delete moved where, so Undo can put it back.
    private var lastTrashed: [(from: URL, to: URL)] = []

    private func deleteSessions(_ ids: [String]) {
        let library = library().sessions.standardizedFileURL.path
        let recording = model?.currentRecordingFolder?.standardizedFileURL.path
        var moved: [(from: URL, to: URL)] = [], skipped = 0
        for id in ids {
            let url = URL(fileURLWithPath: id, isDirectory: true).standardizedFileURL
            // Only session folders inside the library, never the one being recorded.
            guard url.path.hasPrefix(library + "/"), url.path != recording else { skipped += 1; continue }
            var out: NSURL?
            do { try FileManager.default.trashItem(at: url, resultingItemURL: &out) } catch { skipped += 1; continue }
            if let out = out as URL? { moved.append((url, out)) }
            if current?.standardizedFileURL.path == url.path { current = nil }
        }
        lastTrashed = moved
        HotMicLog.write("deleted \(moved.count) session(s) to the Trash, skipped \(skipped)")
        let note = moved.isEmpty ? (recording != nil && skipped > 0 ? "Stop recording to delete this session." : "Couldn't move that to the Trash.") : nil
        js("HM.sideDeleted && HM.sideDeleted(\(moved.count), \(note.map { LabSessionExport.json($0) } ?? "null"))")
        pushAll()
    }

    private func undoDelete() {
        for item in lastTrashed { try? FileManager.default.moveItem(at: item.to, to: item.from) }
        HotMicLog.write("restored \(lastTrashed.count) session(s) from the Trash")
        lastTrashed = []
        pushAll()
    }

    // MARK: - recordings dropped in Freestyle

    func importStatus(_ name: String, progress: Double) {
        js("HM.host.importing({name: \(LabSessionExport.json(name)), progress: \(progress)})")
    }
    func importFinished(_ name: String, folder: URL, takes: Int) {
        js("HM.host.importing({name: \(LabSessionExport.json(name)), done: true, takes: \(takes)})")
        if model?.armedBy == nil { current = folder }      // never yank the window off a live recording
        pushAll()
    }
    func importFailed(_ name: String, _ message: String) {
        js("HM.host.importing({name: \(LabSessionExport.json(name)), error: \(LabSessionExport.json(message))})")
    }

    /// Live input level while recording (0…1, ~15 a second): the strip draws it as it comes in.
    func liveLevel(_ level: Float, at seconds: Double) {
        guard ready, isVisible else { return }
        js("HM.host.level(\(String(format: "%.3f", level)), \(String(format: "%.2f", seconds)))")
    }

    private func pushRecording() {
        js("HM.host.recording(\(model?.armedBy != nil ? "true" : "false"))")
    }

    private func pushMics() {
        let devices = AudioInputs.all(), selected = AudioInputs.defaultID()
        let items = devices.map { "{\"id\":\($0.id),\"name\":\(LabSessionExport.json($0.name))}" }.joined(separator: ",")
        js("HM.host.mics([\(items)], \(selected))")
    }

    /// Coalesced refresh: new takes and lyrics show up while the window is open.
    func refreshSoon() {
        guard isVisible, ready, !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            self.pushAll()
        }
    }

    private func recordingChanged(_ on: Bool) {
        guard ready else { return }
        if on, let folder = model?.currentRecordingFolder { current = folder }
        pushRecording()
        pushAll()
    }

    // MARK: - messages from the page

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        let id = body["id"] as? String, on = body["on"] as? Bool
        let bar = body["bar"] as? [Double], noDrag = body["noDrag"] as? [[Double]], lights = body["lights"] as? [Double]
        let ids = body["ids"] as? [String], mode = body["mode"] as? String
        let text = body["text"] as? String, at = body["at"] as? Double
        Task { @MainActor in
            if cmd == "typeLines" { self.typeLines(text ?? "", at: at ?? 0); return }
            if cmd == "hideRange" || cmd == "unhideRange", let folder = self.current ?? self.model?.currentRecordingFolder {
                if cmd == "hideRange" { HiddenRanges.hide(HiddenRange(a: (body["a"] as? Double) ?? 0, b: (body["b"] as? Double) ?? 0), in: folder) }
                else { HiddenRanges.unhideLast(in: folder) }
                HotMicLog.write("\(cmd) in \(folder.lastPathComponent)")
                self.pushAll(); return
            }
            if cmd == "beatRun", let folder = self.model?.currentRecordingFolder ?? self.current {
                let n = { (k: String) in (body[k] as? Double) ?? 0 }
                BeatRuns.append(BeatRun(at: n("at"), beat: n("beat"), loopA: n("loopA"), loopB: n("loopB"),
                                        loopOn: (body["loopOn"] as? Bool) ?? false, beatName: body["beatName"] as? String), to: folder)
                return
            }
            if cmd == "deleteSessions" { self.deleteSessions(ids ?? []); return }
            if cmd == "record" { self.recordMode = mode }
            self.handle(cmd, id: id, on: on, bar: bar, noDrag: noDrag, lights: lights)
        }
    }

    /// Lines you typed or pasted into the notepad land in the open session like sung lines.
    private func typeLines(_ text: String, at: Double) {
        guard let folder = current ?? model?.currentRecordingFolder ?? model?.newWrittenSession() else { return }
        current = folder
        LiveLines.type(text, at: at, to: folder)
        HotMicLog.write(String(format: "typed %d line(s) at %.1f s", text.split(whereSeparator: \.isNewline).count, at))
        pushAll()
    }

    /// The page only ever names session folders inside the library.
    private func inLibrary(_ path: String) -> Bool {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path.hasPrefix(library().sessions.standardizedFileURL.path + "/")
    }

    private func handle(_ cmd: String, id: String?, on: Bool?, bar: [Double]?, noDrag: [[Double]]?, lights: [Double]? = nil) {
        switch cmd {
        case "ready":
            ready = true
            js(LookPrefs.script)
            if lookObserver == nil {
                lookObserver = NotificationCenter.default.addObserver(forName: LookPrefs.didChange, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.js(LookPrefs.script) }
                }
            }
            if settingsPending { settingsPending = false; js("HM.openSettings()") }
            pushAll()
        case "openSession":
            guard let id, id.isEmpty || inLibrary(id) else { return }
            current = id.isEmpty ? nil : URL(fileURLWithPath: id, isDirectory: true)
            pushAll()
        case "record":
            guard let model else { return }
            if on == true {
                // A session open in the window: keep recording into it. "New session" (＋) starts fresh.
                if model.armedBy == nil { model.startJam(continuing: current, beat: recordMode == "beat") }
            } else if model.armedBy != nil {
                model.toggle()
            }
            pushRecording()
        case "importPick":
            let panel = NSOpenPanel()
            panel.message = "Pick recordings to split into sessions (voice memos, WAV, MP3, AIFF…)"
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [.audio, .movie]
            // Voice Memos keeps its recordings here; start there when it exists.
            let memos = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings", isDirectory: true)
            if FileManager.default.fileExists(atPath: memos.path) { panel.directoryURL = memos }
            guard let window else { return }
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK else { return }
                self?.model?.importRecordings(panel.urls)
            }
        case "undoDelete":
            undoDelete()
        case "revealSession":
            if let id, inLibrary(id) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: id, isDirectory: true)]) }
        case "mode":
            web?.importOnDrop = id == "solo"
        case "setMic":
            if let id, let dev = AudioObjectID(id) { AudioInputs.setDefault(dev) }
            pushMics()
        case "dragRegion":
            if let bar { web?.dragBar = NSRect(x: bar[0], y: bar[1], width: bar[2], height: bar[3]) }
            web?.noDrag = (noDrag ?? []).compactMap { $0.count == 4 ? NSRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
            if let lights, lights.count == 4 { lightsSlot = NSRect(x: lights[0], y: lights[1], width: lights[2], height: lights[3]); placeTrafficLights() }
        default: break
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.placeTrafficLights() }
    }

    // MARK: - window chrome

    /// Where the page leaves room for the traffic lights (its hidden `.lights`), in page coordinates.
    /// Vintage puts it inside the rosewood cheek, Modern and Notebook near the edge.
    private var lightsSlot: NSRect?
    /// The window's mode when Record was pressed ("beat" or "solo").
    private var recordMode: String?

    private func placeTrafficLights() {
        guard let window else { return }
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (i, type) in buttons.enumerated() {
            guard let b = window.standardWindowButton(type), let sup = b.superview else { continue }
            var f = b.frame
            f.origin.x = (lightsSlot?.minX ?? 50) + CGFloat(i) * 20
            f.origin.y = (sup.bounds.height - f.height) / 2
            b.setFrameOrigin(f.origin)
        }
    }
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            if let w = self.window { self.model?.windowClosing(w) }
        }
    }
    nonisolated func windowDidResize(_ notification: Notification) { Task { @MainActor in self.placeTrafficLights() } }
    nonisolated func windowDidBecomeKey(_ notification: Notification) {
        Task { @MainActor in
            self.placeTrafficLights()
            // Coming back to the window (from another app, or after dragging it): the page takes the keyboard.
            if let web = self.web, self.window?.firstResponder !== web { self.window?.makeFirstResponder(web) }
        }
    }
    nonisolated func windowDidExitFullScreen(_ notification: Notification) { Task { @MainActor in self.placeTrafficLights() } }
}

/// Breaks the retain cycle WKUserContentController makes with its handler.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(c, didReceive: m) }
}

/// A web view whose title bar drags the window (everywhere except the controls the page reports).
final class DragWebView: WKWebView {
    var dragBar = NSRect(x: 0, y: 0, width: 100_000, height: 52)
    var noDrag: [NSRect] = []
    /// Freestyle: audio dropped on the window is imported as a session (Beat mode: the page takes it as a beat).
    var importOnDrop = true
    var onImport: (([URL]) -> Void)?
    var onImportHover: ((Bool) -> Void)?
    private let promiseQueue: OperationQueue = { let q = OperationQueue(); q.qualityOfService = .userInitiated; return q }()

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        // Voice Memos (and Photos, Mail…) drag file promises, not file URLs.
        registerForDraggedTypes(registeredDraggedTypes + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) } + [.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func audioURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter(RecordingImport.accepts)
    }
    private func promises(_ info: NSDraggingInfo) -> [NSFilePromiseReceiver] {
        info.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
    }
    private func wantsImport(_ info: NSDraggingInfo) -> Bool {
        importOnDrop && (!audioURLs(info).isEmpty || !promises(info).isEmpty)
    }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        guard wantsImport(info) else { return super.draggingEntered(info) }
        onImportHover?(true)
        return .copy
    }
    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        wantsImport(info) ? .copy : super.draggingUpdated(info)
    }
    override func draggingExited(_ info: NSDraggingInfo?) {
        onImportHover?(false)
        super.draggingExited(info)
    }
    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        guard wantsImport(info) else { return super.performDragOperation(info) }
        onImportHover?(false)
        let urls = audioURLs(info)
        if !urls.isEmpty { onImport?(urls); return true }
        // File promises: the source app writes the file into a folder of ours, then we import it.
        let drop = FileManager.default.temporaryDirectory.appendingPathComponent("hotmic-drops/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: drop, withIntermediateDirectories: true)
        for receiver in promises(info) {
            receiver.receivePromisedFiles(atDestination: drop, options: [:], operationQueue: promiseQueue) { [weak self] url, error in
                guard error == nil else { return }
                DispatchQueue.main.async { self?.onImport?([url]) }
            }
        }
        return true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let top = NSPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y)   // page coordinates, origin top-left
        if dragBar.contains(top), !noDrag.contains(where: { $0.contains(top) }) {
            window?.makeFirstResponder(self)                  // dragging the window keeps the keyboard on the page
            if event.clickCount == 2 { window?.performZoom(nil); return }
            window?.performDrag(with: event)
            return
        }
        super.mouseDown(with: event)
    }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Input devices (the mic picker) and the macOS default input, which capture records from.
enum AudioInputs {
    struct Device { let id: AudioObjectID; let name: String }

    static func all() -> [Device] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter(hasInput).map { Device(id: $0, name: name($0)) }
    }

    static func defaultID() -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    /// Sets the macOS default input (the next session records from it).
    static func setDefault(_ id: AudioObjectID) {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dev = id
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &dev)
    }

    private static func hasInput(_ id: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func name(_ id: AudioObjectID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let s = value?.takeRetainedValue() else { return "Input \(id)" }
        return s as String
    }
}
