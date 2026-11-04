import AppKit
import AVFoundation
import Speech
import CoreAudio
import Capture
import Detection
import Enrichment
import Library
import Overlay
import Session
import SessionKit
import Sparkle
import SwiftUI
import Timeline
import Transcription

/// Shell only: wires contexts together.
@MainActor
final class AppModel: ObservableObject {
    @Published var armedBy: String?
    @Published var lastError: String?
    @Published private(set) var library = LibraryLocation.current()
    @Published private(set) var retentionDays = Retention.current().days
    @Published private(set) var beatsPerBar = max(2, UserDefaults.standard.integer(forKey: "sync.beatsPerBar") == 0 ? 4
                                                   : UserDefaults.standard.integer(forKey: "sync.beatsPerBar"))
    @Published private(set) var tuneMode = Tuner.Mode(rawValue: UserDefaults.standard.string(forKey: "tune.mode") ?? "") ?? .natural
    @Published private(set) var extraDAWs = UserDefaults.standard.stringArray(forKey: "daw.extraBundleIDs") ?? []
    /// Splice-style: the hub comes up by itself when a DAW opens (without taking focus from it).
    @Published var openHubWithDAW = UserDefaults.standard.object(forKey: "hub.openWithDAW") as? Bool ?? true

    let overlay = OverlayState()
    /// Phones joined to the running session (Session step 1: Nearby + QR code).
    let phones = PhonesModel()
    private var room: Room?
    /// Builds a room for the running session (kept so "Let phones join" can start one mid-session).
    private var roomFactory: (() -> Room)?
    private let roomSlot = RoomSlot()
    /// Rooms whose session ended but whose phone takes may still be transcribing.
    private var finishingRooms: [Room] = []
    /// Beatbox → drum takes is built and tested but held back from V1 (Nate, 2026-09-27).
    nonisolated static let beatboxInV1 = false
    /// Sparkle starts only once a feed is configured (SUFeedURL in Info.plist, set by scripts/release.sh).
    let updater = SPUStandardUpdaterController(startingUpdater: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
                                               updaterDelegate: nil, userDriverDelegate: nil)

    private lazy var overlayController = OverlayController(state: overlay)
    private let apps = WorkspaceApplications()
    private var recorder: SessionRecorder?
    private var pipeline: TakePipeline?
    /// Words as you sing them, for the window (Apple on-device speech; Whisper still makes the real lyrics).
    private var liveWords: LiveWords?
    /// Pipelines whose session ended but whose lyric jobs may still be running (quit waits for them).
    private var finishingPipelines: [TakePipeline] = []
    private var stopping: Task<Void, Never>?
    /// The next session is a jam (set by Start jam, consumed by startSession).
    private var jamNext = false
    /// Record pressed with a session open: this run goes on the end of it (Nate 2026-10-12).
    private var continueFolder: URL?
    /// Beat mode: the beat plays in the window, so capture includes Hot Mic's own sound.
    private var beatNext = false
    @Published private(set) var jamming = false
    /// The DAW quit; the session ends when the grace period runs out.
    @Published private(set) var stoppingSoon = false
    private var hotKey: GlobalHotKey?
    /// Always present so DAWs can select "Hot Mic Sync" as a MIDI clock output any time.
    private let sync: SyncPort? = try? SyncPort()
    /// One shared model; loads in the background at launch (first run downloads it once).
    private let transcriber = WhisperTranscriber(downloadBase: WhisperTranscriber.modelFolder())
    private lazy var watcher = DAWWatcher(
        source: apps, catalog: DAWCatalog.standard.adding(bundleIDs: extraDAWs), scheduler: MainQueueScheduler(),
        onArm: { [weak self] daw in self?.startSession(for: daw) },
        onDisarm: { [weak self] in self?.stopSession() })

    private lazy var hub = HubModel(index: LibraryIndex(location: library), transcriber: transcriber)
    private var hubWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var hubCloseObserver: NSObjectProtocol?
    private var hubRefreshPending = false
    /// The designed window (web UI fed with the real library). The SwiftUI hub stays as "Classic hub".
    private lazy var labWindow = LabWindowController(model: self, library: { [weak self] in self?.library ?? LibraryLocation.current() })
    var currentRecordingFolder: URL? { recordingFolder }

    init() {
        AppDelegate.model = self
        TakePipeline.sweepOrphanedScratch()          // leftovers from a crash; no session is running yet
        overlay.toggle = { [weak self] in self?.toggle() }
        overlay.startJam = { [weak self] in self?.startJam() }
        hotKey = GlobalHotKey.openHotMic { [weak self] in self?.showHub(activate: true) }
        overlay.openHub = { [weak self] in self?.showHub(activate: true) }
        overlay.openFolder = { [weak self] in self?.openLibrary() }
        overlayController.appWindowFront = { [weak self] in NSApp.isActive && self?.labWindow.window?.isKeyWindow == true }
        overlay.onPreview = { [weak self] seconds in self?.pipeline?.muteDetection(for: seconds) }
        sync?.beatsPerBar = beatsPerBar
        hub.onPreview = { [weak self] seconds in self?.pipeline?.muteDetection(for: seconds) }
        hub.recordingFolder = { [weak self] in self?.recordingFolder }
        phones.answer = { [weak self] request, allow in self?.room?.answer(request, allow: allow) }
        phones.remove = { [weak self] device in self?.room?.remove(device: device) }
        phones.onEnabledChange = { [weak self] on in on ? self?.startRoom() : self?.stopRoom() }
        sweepRetention()
        let transcriber = self.transcriber
        Task.detached(priority: .background) { try? await transcriber.prepare() }
        // Nothing listens until the user has seen what Hot Mic does and why it asks for the mic.
        // Deferred one turn: init runs while SwiftUI builds the app, and the overlay (and an
        // already-open DAW arming a session) must not update views in the middle of that.
        if UserDefaults.standard.bool(forKey: "onboarded") {
            DispatchQueue.main.async { self.beginListening() }
        } else {
            DispatchQueue.main.async { self.showOnboarding() }
        }
    }

    private func beginListening() {
        // Bench run (BenchLive): a recording through the live session path; no DAW watching, no overlay.
        if BenchLive.start(arguments: ProcessInfo.processInfo.arguments,
                           settings: PipelineSettings(tuneMode: tuneMode, transcriber: transcriber, library: library),
                           lineTranscriber: transcriber) { return }
        watcher.onClosing = { [weak self] closing in
            self?.stoppingSoon = closing
            self?.overlay.stopping = closing
        }
        watcher.start()
        overlayController.start()
        // Diagnostics: `open -a "Hot Mic" --args --selftest-capture` records a 6 s jam, stops, and quits.
        // Diagnostics: `open -a "Hot Mic" --args --selftest-live <audio file>` plays a recording into live words in
        // real time (the same LiveWords the session uses), logs every line to hotmic.log, and quits.
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "--selftest-live"), ProcessInfo.processInfo.arguments.count > i + 1 {
            let url = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[i + 1])
            LiveWords.requestPermission { ok in
                HotMicLog.write("selftest-live: \(url.lastPathComponent), speech permission \(ok)")
                guard ok, let file = try? AVAudioFile(forReading: url),
                      let mono = AVAudioFormat(standardFormatWithSampleRate: file.processingFormat.sampleRate, channels: 1),
                      let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                      (try? file.read(into: buf)) != nil, let data = buf.floatChannelData else { exit(1) }
                let live = LiveWords(), rate = mono.sampleRate, n = Int(buf.frameLength)
                var lines = 0
                let lab = self.labWindow
                live.onLine = { text, at, end, _, _ in lines += 1; lab.lineDone(text, at: at, end: end); HotMicLog.write(String(format: "selftest-live: line %.1f–%.1f \"%@\"", at, end, text)) }
                live.onWords = { text, final in lab.live(text, final: final); if !text.isEmpty { HotMicLog.write("selftest-live: partial \"\(text)\"") } }
                if ProcessInfo.processInfo.arguments.contains("--show") { self.showHub(activate: false); DispatchQueue.main.asyncAfter(deadline: .now() + 2) { lab.selftestRecording(true) } }
                live.onNotice = { n in if let n { HotMicLog.write("selftest-live: notice \(n)") } }
                let samples = Array(UnsafeBufferPointer(start: data[0], count: n)) + [Float](repeating: 0, count: Int(rate * 3))   // + 3 s quiet
                live.start(sampleRate: rate)
                let lead = ProcessInfo.processInfo.arguments.contains("--show") ? 3.0 : 0
                DispatchQueue.global().asyncAfter(deadline: .now() + lead) {
                    let hop = 1024; var k = 0
                    while k < samples.count {
                        let m = min(hop, samples.count - k)
                        samples[k..<(k + m)].withUnsafeBufferPointer { live.feed($0) }
                        k += m; Thread.sleep(forTimeInterval: Double(m) / rate)
                    }
                    DispatchQueue.main.async {
                        live.stop()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { HotMicLog.write("selftest-live: done, \(lines) line(s)"); exit(0) }
                    }
                }
            }
        }
        // Diagnostics: `--ui-js "<script>"` opens the window and runs page script after 2.5 s (screenshots of states).
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "--ui-js"), ProcessInfo.processInfo.arguments.count > i + 1 {
            let script = ProcessInfo.processInfo.arguments[i + 1]
            showHub(activate: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.labWindow.debugJS(script) }
        }
        if ProcessInfo.processInfo.arguments.contains("--selftest-capture") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.startJam()
                NSLog("Hot Mic selftest: started, folder=\(self?.recordingFolder?.path ?? "nil")")
                let args = ProcessInfo.processInfo.arguments
                let secs = args.firstIndex(of: "--selftest-capture").flatMap { i in args.count > i + 1 ? Double(args[i + 1]) : nil } ?? 6
                DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
                    self?.toggle()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { exit(0) }   // terminate() hangs here and leaves a stray copy running
                }
            }
        }
    }

    // MARK: - settings

    func setLibrary(_ url: URL) {
        library = LibraryLocation(root: url)
        library.save()
        hub.use(LibraryIndex(location: library))
    }

    func setRetentionDays(_ days: Int) {
        retentionDays = days
        UserDefaults.standard.set(days, forKey: "library.retentionDays")
    }

    func setBeatsPerBar(_ beats: Int) {
        beatsPerBar = beats
        sync?.beatsPerBar = beats
        UserDefaults.standard.set(beats, forKey: "sync.beatsPerBar")
    }

    func setTuneMode(_ mode: Tuner.Mode) {
        tuneMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "tune.mode")
    }

    /// Returns the entries that were rejected as not being bundle IDs.
    @discardableResult
    func setExtraDAWs(_ ids: [String]) -> [String] {
        let trimmed = ids.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        extraDAWs = trimmed.filter(DAWCatalog.isValidBundleID)
        UserDefaults.standard.set(extraDAWs, forKey: "daw.extraBundleIDs")
        watcher.catalog = DAWCatalog.standard.adding(bundleIDs: extraDAWs)
        watcher.refresh()                                   // a newly listed app that's already open arms now
        return trimmed.filter { !DAWCatalog.isValidBundleID($0) }
    }

    func setOpenHubWithDAW(_ on: Bool) {
        openHubWithDAW = on
        UserDefaults.standard.set(on, forKey: "hub.openWithDAW")
    }

    // MARK: - windows (a dock icon only while a real window is open)

    func showOnboarding() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView(model: self) { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(true, forKey: "onboarded")
            self.onboardingWindow?.close()
            self.onboardingWindow = nil
            self.updateActivationPolicy()
            self.beginListening()
        }))
        window.title = "Welcome to Hot Mic"
        window.styleMask.remove(.resizable)
        window.styleMask.remove(.closable)       // the only way out is finishing it (or Quit)
        window.isReleasedWhenClosed = false
        window.center()
        onboardingWindow = window
        updateActivationPolicy(forceRegular: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Settings… / ⌘,: open the Hot Mic window and its Settings popover (style, accent, light/dark).
    func openLookSettings() {
        showHub(activate: true)
        labWindow.openSettings()
    }

    func showHub(activate: Bool) {
        updateActivationPolicy(forceRegular: true)
        labWindow.show(activate: activate)
    }

    /// Called by the Hot Mic window when it closes, so the Dock icon goes away with it.
    func windowClosing(_ window: NSWindow) { updateActivationPolicy(closing: window) }

    func showClassicHub(activate: Bool) {
        if hubWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: HubView(model: hub, phones: phones)))
            window.title = "Hot Mic"
            window.appearance = NSAppearance(named: .aqua)   // light by default (never ship dark-by-default)
            window.setContentSize(NSSize(width: 980, height: 640))
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("HotMicHub")
            hubCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                                      queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateActivationPolicy(closing: window) }
            }
            hubWindow = window
        }
        updateActivationPolicy(forceRegular: true)
        hub.reload()
        if activate {
            hubWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            hubWindow?.orderFrontRegardless()
        }
    }

    private func updateActivationPolicy(forceRegular: Bool = false, closing: NSWindow? = nil) {
        let visible = [hubWindow, onboardingWindow, labWindow.window].contains { w in
            guard let w, w !== closing else { return false }
            return w.isVisible
        }
        NSApp.setActivationPolicy(forceRegular || visible ? .regular : .accessory)
    }

    /// Coalesced: the hub shows new takes and lyrics while it's open.
    private func refreshHubSoon() {
        labWindow.refreshSoon()
        guard hubWindow?.isVisible == true, !hubRefreshPending else { return }
        hubRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.hubRefreshPending = false
            self?.hub.reload()
        }
    }

    // MARK: - sessions

    var isOnboarded: Bool { UserDefaults.standard.bool(forKey: "onboarded") }

    func toggle() {
        guard isOnboarded else { showOnboarding(); return }   // no recording before the explanation
        if armedBy == nil { withMicrophone { [weak self] in self?.toggle() }; if !micAllowed { return } }
        if armedBy == nil { askForLiveWords() }
        userStarted = armedBy == nil
        armedBy == nil ? watcher.armManually() : watcher.disarmManually()
    }

    private var micAllowed: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    /// Arming before the microphone is allowed records a session with no audio in it (the HAL delivers
    /// nothing while the prompt is up). Ask first; `then` runs once access is granted.
    private func withMicrophone(then: @escaping () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { [weak self] in
                    if granted { then() } else { self?.micDenied() }
                }
            }
        default: micDenied()
        }
    }

    private func micDenied() {
        lastError = "Hot Mic can't hear the microphone. Allow it in System Settings → Privacy & Security → Microphone."
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    /// First recording: ask for on-device speech recognition (live words). If it's granted while a
    /// session is already running, live words switch on for that session.
    private func askForLiveWords() {
        LiveWords.requestPermission { [weak self] granted in
            if granted { self?.liveWords?.retry() }
        }
    }

    /// Set when you pressed Turn on / Start jam yourself: a failure then gets an alert, not just menu text.
    private var userStarted = false
    private var recordingFolder: URL?

    /// Songwriting jam: no DAW, one mic hearing your instrument and voice. Anything musical becomes
    /// a take with its tempo, key and chords; talking in between is dropped.
    func startJam(continuing folder: URL? = nil, beat: Bool = false) {
        guard isOnboarded else { showOnboarding(); return }
        guard micAllowed else { withMicrophone { [weak self] in self?.startJam(continuing: folder, beat: beat) }; return }
        beatNext = beat
        askForLiveWords()
        if armedBy != nil { watcher.disarmManually() }
        jamNext = true
        continueFolder = folder
        userStarted = true
        watcher.armManually()
    }

    /// Recordings dropped on the window in Freestyle (Voice Memos, any audio file): each becomes its
    /// own session through the jam pipeline, and opens in the window when it's split.
    func importRecordings(_ urls: [URL]) {
        let settings = PipelineSettings(tuneMode: tuneMode, transcriber: transcriber, library: library)
        let lab = labWindow
        for url in urls where RecordingImport.accepts(url) {
            let name = url.deletingPathExtension().lastPathComponent
            let folder = uniqueSessionFolder(for: DAWCatalog.Entry(name: name, bundleID: "io.bluegum.hotmic.import"))
            lab.importStatus(name, progress: 0)
            Task.detached(priority: .userInitiated) {
                var shown = 0
                do {
                    let takes = try await RecordingImport.run(
                        url: url, folder: folder,
                        configure: { settings.configure($0, jam: true, onLyrics: { _, _ in }) },
                        progress: { p in
                            let pct = Int(p * 100); guard pct >= shown + 2 else { return }
                            shown = pct
                            Task { @MainActor in lab.importStatus(name, progress: p) }
                        })
                    await MainActor.run { lab.importFinished(name, folder: folder, takes: takes.count) }
                } catch {
                    try? FileManager.default.removeItem(at: folder)
                    await MainActor.run { lab.importFailed(name, "\(error)") }
                }
            }
        }
    }

    private func startSession(for daw: DAWCatalog.Entry) {
        let jam = jamNext
        jamNext = false
        let resume = jam ? continueFolder.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } : nil
        continueFolder = nil
        // Picking up an existing session: new audio, takes and lines start where it left off.
        let resumeSegments = resume.map { f in ((try? FileManager.default.contentsOfDirectory(atPath: f.path)) ?? [])
            .filter { $0.hasPrefix("session__voice_") && $0.hasSuffix(".m4a") }.sorted() } ?? []
        let offset: Double = resume.map { f in resumeSegments.reduce(0.0) { sum, name in
            guard let file = try? AVAudioFile(forReading: f.appendingPathComponent(name)) else { return sum }
            return sum + Double(file.length) / file.processingFormat.sampleRate
        } } ?? 0
        let firstSegment = resumeSegments.count + 1
        let label = jam ? "Jam" : daw.name
        // A jam listens to the whole Mac (a backing track still gets cancelled on speakers).
        let pid = jam ? nil : NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier.flatMap(watcher.catalog.match) == daw
        }?.processIdentifier
        let folder = resume ?? uniqueSessionFolder(for: jam ? DAWCatalog.Entry(name: "Jam", bundleID: "io.bluegum.hotmic.jam") : daw)
        if resume != nil { HotMicLog.write(String(format: "continuing %@ at %.1f s", folder.lastPathComponent, offset)) }
        let overlay = self.overlay
        let sync = self.sync
        let lab = self.labWindow
        let withBeat = beatNext
        beatNext = false
        let source = CoreAudioCaptureSource(target: pid.map { .process($0) } ?? (withBeat ? .systemAudioWithOwn : .systemAudio))
        source.onProblem = { [weak self] message in
            DispatchQueue.main.async { self?.lastError = message.isEmpty ? nil : message }
        }
        source.onFailure = { [weak self] message in
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastError = message
                self.watcher.disarmAfterFailure()       // honest state: capture is dead, so the session ends
            }
        }
        var sessionPipeline: TakePipeline?
        var sessionRoomFactory: (() -> Room)?
        let recorder = SessionRecorder(source: source) { rate in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let processor = AdaptiveVoiceProcessor(sampleRate: rate, prior: RoutePrior.currentOutput())
            let pipeline = try TakePipeline(folder: folder, sampleRate: rate, sessionStart: Date(), daw: label, jam: jam,
                                            route: { "\(processor.route)" })
            let readout = jam ? LiveJamAnalyzer(sampleRate: rate) : nil
            let live = LiveWords()
            live.onWords = { [weak self] text, final in self?.labWindow.live(text, final: final) }
            // AirPods-class mics filter for speech: say so up front, or hums and beatboxing just vanish.
            let micWarning = RoutePrior.bluetoothInputName().map {
                "\($0) filters out hums and beatboxing. For those, switch the input to your Mac's mic or interface in System Settings › Sound."
            }
            live.onNotice = { [weak self] notice in self?.labWindow.liveNotice(notice ?? micWarning) }
            if let micWarning { DispatchQueue.main.async { lab.liveNotice(micWarning) } }
            let lineTranscriber: WhisperTranscriber? = self.transcriber
            var recent: [String] = []                       // the hint: what you've sung so far
            live.onLine = { text, at, end, audio, cut in
                guard LiveLines.append(LiveLine(text: text, at: at, end: end, cut: cut ? true : nil), to: folder) else {
                    lab.liveNotice("Couldn't save this lyric line. Check the library folder.")
                    return
                }
                lab.lineDone(text, at: at, end: end)
                lab.refreshSoon()
                // Whisper on just this line's audio: corrected in place a moment later.
                guard let lineTranscriber, audio.count > Int(rate * 0.3) else { return }
                let hint = recent.suffix(4).joined(separator: " ")
                recent.append(text)
                Task.detached(priority: .userInitiated) {
                    // A quiet mic (AirPods across the room, −43 dB): bring the clip up before Whisper hears it,
                    // the way saved takes are levelled (Nate 2026-10-13, E3).
                    let levelled = Loudness().normalize(audio, channels: 1, sampleRate: rate)
                    guard let lyrics = try? await lineTranscriber.transcribe(levelled, sampleRate: rate, hint: hint) else { return }
                    let fixed = lyrics.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !fixed.isEmpty, !LiveLines.isJunk(fixed) else { return }
                    guard LiveLines.fix(at: at, text: fixed, in: folder) else {
                        await MainActor.run { lab.liveNotice("Couldn't save the lyric correction. Check the library folder.") }
                        return
                    }
                    HotMicLog.write(String(format: "line fix %.1f s", at))
                    await MainActor.run { lab.refreshSoon() }
                }
            }
            live.timeOffset = offset
            live.start(sampleRate: rate)
            DispatchQueue.main.async { [weak self] in self?.liveWords = live }
            readout?.onReadout = { r in
                DispatchQueue.main.async {
                    overlay.jamChord = r.chord; overlay.jamKey = r.key; overlay.jamBPM = r.bpm; overlay.jamNote = r.note
                }
            }
            sessionPipeline = pipeline
            pipeline.positionAt = { frame in
                guard let sync, source.hostTimeAtFirstFrame != 0 else { return nil }
                // Stamp when the singer sang: output frame − processing latency − mic input latency.
                let clock = FrameClock(hostAtFrameZero: source.hostTimeAtFirstFrame, sampleRate: rate,
                                       ticksPerSecond: sync.ticksPerSecond,
                                       latencyFrames: Int64(processor.latencyFrames + source.inputLatencyFrames))
                return sync.position(at: clock.host(atOutputFrame: frame))
            }
            let settings = PipelineSettings(tuneMode: self.tuneMode,
                                            transcriber: self.transcriber, library: self.library)
            let onLyrics: @Sendable (String, Lyrics) -> Void = { [weak self] id, lyrics in
                DispatchQueue.main.async { overlay.setLyrics(lyrics.text, forTake: id); self?.refreshHubSoon() }
            }
            settings.configure(pipeline, jam: jam, onLyrics: onLyrics)
            if jam && withBeat { pipeline.judge = JamJudge(beat: true) }   // the beat's bleed is never your playing
            pipeline.timeOffset = offset
            pipeline.referenceContainsVoice = { processor.referenceContainsVoice }
            // Phones in the room: they hear this session's audio and sing takes into the same folder.
            let tap = ReferenceTap(sampleRate: rate)
            let sessionStart = Date()
            let roomHost = RemoteSinger.Host(
                tap: tap,
                secondsAtFrameZero: { source.hostTimeAtFirstFrame == 0 ? nil : HostClock.seconds(fromHostTime: source.hostTimeAtFirstFrame) },
                positionAt: { frame in
                    guard let sync, source.hostTimeAtFirstFrame != 0 else { return nil }
                    let clock = FrameClock(hostAtFrameZero: source.hostTimeAtFirstFrame, sampleRate: rate,
                                           ticksPerSecond: sync.ticksPerSecond, latencyFrames: 0)
                    return sync.position(at: clock.host(atOutputFrame: frame))
                },
                makePipeline: { _, startFrame in
                    let singerPipeline = try TakePipeline(folder: folder, sampleRate: rate,
                                                          sessionStart: sessionStart.addingTimeInterval(Double(startFrame) / rate),
                                                          daw: label, jam: false)
                    settings.configure(singerPipeline, jam: false, onLyrics: onLyrics)
                    return singerPipeline
                },
                folder: folder)
            let hostName = Host.current().localizedName ?? "Hot Mic"
            sessionRoomFactory = { Room(hostName: hostName, sessionName: label, host: roomHost,
                                        isTrusted: { [trusted = self.phones.trustedDevices] in trusted.contains($0) }) }
            pipeline.onTake = { [weak self] take in
                let item = OverlayTake(id: take.id, title: Self.takeTitle(take), seconds: Int(take.durationSeconds.rounded()),
                                       voiceURL: folder.appendingPathComponent(take.files["voice"] ?? ""),
                                       mixURL: folder.appendingPathComponent(take.files["mix"] ?? ""))
                DispatchQueue.main.async { overlay.add(item); self?.refreshHubSoon() }
                live.nextLine()
            }
            let voiceSink: SegmentedAACWriter, mixSink: SegmentedAACWriter
            do {
                voiceSink = try SegmentedAACWriter(folder: folder, baseName: "session__voice", sampleRate: rate, channels: 1, bitRate: 96_000, firstIndex: firstSegment)
                mixSink = try SegmentedAACWriter(folder: folder, baseName: "session__mix", sampleRate: rate, channels: 2, bitRate: 192_000, firstIndex: firstSegment)
            } catch {
                pipeline.abandon()        // no session: no scratch left behind
                throw error
            }
            let mixer = SessionMixer(
                voiceSink: voiceSink,
                mixSink: mixSink,
                processor: processor,
                hardwareDelayFrames: source.roundTripLatencyFrames)
            var lastMeter = Date.distantPast
            var held: Float = 0        // loudest sample since the last meter update (was: only the current chunk)
            mixer.onMixed = { voice, mix, frames, position in
                pipeline.consume(voice: voice, mix: mix, frames: frames, position: position)
                readout?.feed(UnsafeBufferPointer(rebasing: voice[0..<frames]))
                live.feed(UnsafeBufferPointer(rebasing: voice[0..<frames]))
                for i in 0..<frames { held = max(held, abs(voice[i])) }
                guard Date().timeIntervalSince(lastMeter) >= 1.0 / 20 else { return }   // the strip draws 20 values a second
                lastMeter = Date()
                let peak = held
                held = 0
                let level = max(0, min(1, (20 * log10(peak + 1e-6) + 50) / 50))  // −50…0 dBFS → 0…1
                let speakers = processor.route != .headphones
                let now = offset + Double(position + Int64(frames)) / rate        // the recording's own clock
                DispatchQueue.main.async { overlay.level = level; overlay.onSpeakers = speakers }
                Task { @MainActor in lab.liveLevel(level, at: now) }
            }
            let roomSlot = self.roomSlot
            mixer.onSession = { chunk, frames, position in
                tap.append(chunk, frames: frames, at: position)
                roomSlot.room?.beat(chunk, frames: frames, at: position)
            }
            mixer.onFinish = { try pipeline.finish() }
            return mixer
        }
        do {
            try recorder.start()
            self.recorder = recorder
            self.pipeline = sessionPipeline
            roomFactory = sessionRoomFactory
            phones.recording = true
            if phones.enabled { startRoom() }
            recordingFolder = folder
            armedBy = label
            jamming = jam
            overlay.isOn = true
            overlay.jamming = jam
            overlay.source = label
            lastError = nil
            if openHubWithDAW, !jam, daw != DAWWatcher.manual {
                // The very first time, bring it to the front so you know Hot Mic is there; after that it
                // opens quietly behind your DAW.
                let introduced = UserDefaults.standard.bool(forKey: "hub.introduced")
                UserDefaults.standard.set(true, forKey: "hub.introduced")
                showHub(activate: !introduced)
            }
        } catch {
            lastError = "\(error)"
            watcher.disarmAfterFailure()
            // Nothing was recorded: don't leave an empty session behind.
            if let items = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
               items.allSatisfy({ $0.hasPrefix(".") || $0.hasSuffix(".m4a") && Self.fileSize(folder.appendingPathComponent($0)) < 8_192 }) {
                try? FileManager.default.removeItem(at: folder)
            }
            if userStarted {
                let alert = NSAlert()
                alert.messageText = "Hot Mic couldn't start recording"
                alert.informativeText = "\(error.localizedDescription)\n\nMic: \(Self.inputDeviceName())"
                alert.alertStyle = .warning
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
        userStarted = false
    }

    static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// The system's default input device name (for error messages).
    static func inputDeviceName() -> String {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return "unknown" }
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else { return "unknown" }
        return name.takeRetainedValue() as String
    }

    /// Two sessions in the same minute (DAW relaunch) must never share — or overwrite — a folder.
    /// Typing into an empty session (Nate 2026-10-14: the board is always typeable): the words get a session of their own.
    func newWrittenSession() -> URL? {
        let folder = uniqueSessionFolder(for: DAWCatalog.Entry(name: "Jam", bundleID: "io.bluegum.hotmic.jam"))
        return (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil ? folder : nil
    }

    private func uniqueSessionFolder(for daw: DAWCatalog.Entry) -> URL {
        let safeName = daw.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let base = "\(Self.folderDate.string(from: Date())) \(safeName)"
        var folder = library.sessions.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = library.sessions.appendingPathComponent("\(base) (\(n))", isDirectory: true)
            n += 1
        }
        return folder
    }

    /// UI updates immediately; finishing files and the last take happens off the main thread.
    private func stopSession() {
        let recorder = self.recorder, pipeline = self.pipeline, room = self.room
        let folderOfStoppedSession = recordingFolder
        liveWords?.stop(); liveWords = nil
        self.recorder = nil
        self.pipeline = nil
        self.room = nil
        roomSlot.room = nil
        roomFactory = nil
        phones.recording = false
        phones.snapshot = Room.Snapshot()
        recordingFolder = nil
        armedBy = nil
        jamming = false
        overlay.isOn = false
        overlay.jamming = false
        overlay.jamChord = nil; overlay.jamKey = nil; overlay.jamBPM = nil; overlay.jamNote = nil
        overlay.source = nil
        overlay.level = 0
        guard let recorder else { return }
        let judged = pipeline.flatMap { _ in folderOfStoppedSession }
        if let pipeline { finishingPipelines.append(pipeline) }
        if let room { finishingRooms.append(room) }
        // Finalization is serialized (files close in order) but never waits on an earlier session's lyrics.
        let previousStop = stopping
        let stop = Task.detached(priority: .userInitiated) { () -> String? in
            await previousStop?.value
            defer { room?.stop() }          // after the recorder: phones get every last frame of the beat
            do { try recorder.stop(); return nil } catch { return "\(error)" }
        }
        stopping = Task { _ = await stop.value }
        Task { @MainActor [weak self] in
            if let failure = await stop.value { self?.lastError = failure }
            self?.sweepRetention()
            self?.refreshHubSoon()
            if let room {
                await room.waitForLyrics()
                self?.finishingRooms.removeAll { $0 === room }
            }
            guard let pipeline else { return }
            await pipeline.waitForLyrics()
            self?.finishingPipelines.removeAll { $0 === pipeline }
            if let judged { self?.labWindow.judgeSoon(judged) }      // the words are in: the model pass reads them
        }
    }

    var hasUnfinishedWork: Bool { recorder != nil || stopping != nil || !finishingPipelines.isEmpty || !finishingRooms.isEmpty }

    /// Quit: finish writing every session's files (bounded generously), then give lyrics up to
    /// `lyricTimeout` seconds. Never hangs.
    func finishForQuit(lyricTimeout: Double) async {
        stopSession()
        await Self.race(seconds: 120) { [stopping] in await stopping?.value }
        let pending = finishingPipelines, rooms = finishingRooms
        await Self.race(seconds: lyricTimeout) {
            for p in pending { await p.waitForLyrics() }
            for r in rooms { await r.waitForLyrics() }
        }
    }

    /// Runs `work`, returning when it finishes or after `seconds`, whichever comes first.
    private static func race(seconds: Double, _ work: @escaping @Sendable () async -> Void) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let once = OnceFlag()
            Task { await work(); if once.claim() { done.resume() } }
            Task { try? await Task.sleep(for: .seconds(seconds)); if once.claim() { done.resume() } }
        }
    }

    private func sweepRetention() {
        let (sessions, retention) = (library.sessions, Retention.current())
        DispatchQueue.global(qos: .utility).async { retention.sweep(sessions) }
    }

    // MARK: - phones

    /// Opens the session to phones (QR code + Nearby). Only while a session records.
    func startRoom() {
        guard room == nil, let factory = roomFactory else { return }
        let room = factory()
        room.onChange = { [weak self] snapshot in self?.phones.snapshot = snapshot }
        room.onRequest = { [weak self] request in
            guard let self else { return }
            NSSound(named: "Glass")?.play()
            self.showClassicHub(activate: false)
            self.hub.selection = .phones
            _ = request
        }
        let overlay = self.overlay, folder = recordingFolder
        room.onTake = { [weak self] take in
            guard let folder else { return }
            let item = OverlayTake(id: take.id, title: "\(take.singer ?? "Phone") · \(Self.takeTitle(take))",
                                   seconds: Int(take.durationSeconds.rounded()),
                                   voiceURL: folder.appendingPathComponent(take.files["voice"] ?? ""),
                                   mixURL: folder.appendingPathComponent(take.files["mix"] ?? ""))
            DispatchQueue.main.async { overlay.add(item); self?.refreshHubSoon() }
        }
        room.start()
        self.room = room
        roomSlot.room = room
    }

    /// Closes the session to phones; their takes so far stay.
    func stopRoom() {
        guard let room else { return }
        self.room = nil
        roomSlot.room = nil
        phones.snapshot = Room.Snapshot()
        finishingRooms.append(room)
        Task.detached(priority: .userInitiated) {
            room.stop()
            await room.waitForLyrics()
            await MainActor.run { [weak self] in self?.finishingRooms.removeAll { $0 === room }; self?.refreshHubSoon() }
        }
    }

    func openLibrary() {
        try? FileManager.default.createDirectory(at: library.sessions, withIntermediateDirectories: true)
        NSWorkspace.shared.open(library.sessions)
    }

    static func takeTitle(_ take: TakeRecord) -> String {
        let time = clock.string(from: take.createdAt)
        guard let p = take.position, p.playing else {
            if let t = take.tempo, t.confidence > 0.2 { return "\(Int(t.bpm.rounded())) BPM · \(time)" }
            return time
        }
        return "Bar \(p.bar) · \(Int(p.tempo.rounded())) BPM · \(time)"
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        return f
    }()

    private static let folderDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return f
    }()
}

/// Resumes a continuation exactly once across racing tasks.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
}

/// Quitting (menu, logout, Sparkle relaunch) mid-session must finalize the session files and the
/// last take, and give in-flight lyrics a moment — otherwise work is lost.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var model: AppModel?

    /// Clicking Hot Mic in the Dock (or opening it again from Applications/Spotlight) while it's
    /// already running opens the dashboard.
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.model?.showHub(activate: true)
        return true
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model, model.hasUnfinishedWork else { return .terminateNow }
        Task { @MainActor in
            await model.finishForQuit(lyricTimeout: 20)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct HotMicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    init() { NSApplication.shared.setActivationPolicy(.accessory) }  // no dock icon

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model, overlay: model.overlay)
        } label: {
            Image(nsImage: MenuBarIcon.image(recording: model.armedBy != nil))
        }
        Settings { SettingsView(model: model) }
            .commands { CommandGroup(replacing: .appSettings) { SettingsCommands(model: model) } }
    }
}

/// App menu: Settings… (⌘,) opens the one Settings window (Look, General, DAW Sync).
private struct SettingsCommands: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Button("Settings…") { NSApp.activate(ignoringOtherApps: true); openSettings() }.keyboardShortcut(",", modifiers: .command)
    }
}

private struct MenuContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var overlay: OverlayState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(model.stoppingSoon ? "Stopping… (\(model.armedBy ?? "DAW") closed)"
             : model.armedBy.map { "Recording · \($0)" } ?? "Off")
        if let error = model.lastError { Text(error) }
        Button(model.armedBy == nil ? "Turn on" : "Turn off") { model.toggle() }
        if !model.jamming { Button("Start jam") { model.startJam() } }
        if model.jamming, let chord = overlay.jamChord {
            Text([chord, overlay.jamKey, overlay.jamBPM.map { "\($0) BPM" }].compactMap { $0 }.joined(separator: " · "))
        }
        ForEach(model.phones.snapshot.requests) { request in
            Button("Let \(request.name) join") { model.phones.allow(request, always: false) }
            Button("Don't let \(request.name) join") { model.phones.deny(request) }
        }
        if model.armedBy != nil, !model.phones.snapshot.singers.isEmpty {
            Text("Phones: " + model.phones.snapshot.singers.map(\.name).joined(separator: ", "))
        }
        Button("Open Hot Mic") { model.showHub(activate: true) }
            .keyboardShortcut("h", modifiers: [.control, .option])
        Button("Open takes folder") { model.openLibrary() }
        Button("Classic hub") { model.showClassicHub(activate: true) }
        if !overlay.takes.isEmpty {
            Divider()
            Text("Recent takes")
            ForEach(overlay.takes) { take in
                Button("\(take.title) · \(take.seconds) s") { overlay.play(take) }
            }
        }
        Divider()
        LookMenus()
        Divider()
        Picker("When idle", selection: Binding(get: { overlay.settings.idleMode },
                                               set: { mode in overlay.update { $0.idleMode = mode } })) {
            Text("Ghost (faint pill)").tag(IdleMode.ghost)
            Text("Invisible (hover the edge)").tag(IdleMode.invisible)
        }
        Picker("Position", selection: Binding(get: { overlay.settings.position },
                                              set: { p in overlay.update { $0.position = p } })) {
            Text("Top center").tag(PillPosition.topCenter)
            Text("Top left").tag(PillPosition.topLeft)
            Text("Top right").tag(PillPosition.topRight)
            Text("Bottom left").tag(PillPosition.bottomLeft)
            Text("Bottom right").tag(PillPosition.bottomRight)
        }
        Toggle("Flash when a take is caught", isOn: Binding(get: { overlay.settings.flashOnTake },
                                                           set: { v in overlay.update { $0.flashOnTake = v } }))
        Divider()
        Button("Check for Updates…") { model.updater.checkForUpdates(nil) }
            .disabled(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") == nil)
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)   // bring Settings in front of the DAW
            openSettings()
        }
        Button("Quit Hot Mic") { NSApplication.shared.terminate(nil) }
    }
}

/// The room the drain queue should stream the beat to (swapped from the main thread).
final class RoomSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Room?
    var room: Room? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// What every take pipeline in a session shares — the host's own and each phone singer's.
/// Built on the main thread, used from any queue.
struct PipelineSettings: @unchecked Sendable {
    let tuneMode: Tuner.Mode
    let transcriber: WhisperTranscriber
    let library: LibraryLocation

    func configure(_ pipeline: TakePipeline, jam: Bool, onLyrics: @escaping @Sendable (String, Lyrics) -> Void) {
        if !jam { pipeline.judge = AppleVoiceJudge() }   // jam keeps its music-accepting JamJudge
        pipeline.beatboxEnabled = AppModel.beatboxInV1
        var options = ExportOptions()
        options.tuneMode = tuneMode
        pipeline.options = options
        pipeline.transcriber = transcriber
        let index = LibraryIndex(location: library)
        pipeline.catalog = { LyricIndex(index.lyricDocuments()) }
        pipeline.onLyrics = onLyrics
    }
}


/// Style, accent and light/dark right in the menu bar menu (same settings as Settings → Look).
private struct LookMenus: View {
    @AppStorage(LookPrefs.modeKey) private var mode = "dark"
    @AppStorage(LookPrefs.accentKey) private var accent = "lilac"
    var body: some View {
        Picker("Look", selection: Binding(get: { mode }, set: { mode = $0; LookPrefs.changed() })) {
            ForEach(LookPrefs.modes, id: \.0) { Text($0.1).tag($0.0) }
        }
        Picker("Accent", selection: Binding(get: { accent }, set: { accent = $0; LookPrefs.changed() })) {
            ForEach(LookPrefs.accents, id: \.0) { Text($0.1).tag($0.0) }
        }
    }
}
