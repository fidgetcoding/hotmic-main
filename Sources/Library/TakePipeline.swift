import Capture
import Detection
import Enrichment
import Foundation
import Timeline

/// Everything that turns the processed session stream into takes on disk.
/// Runs on the recorder's drain queue: feed it via `SessionMixer.onMixed`.
public final class TakePipeline {
    /// Called on the export queue (not the capture drain queue) when a take's files are written.
    public var onTake: ((TakeRecord) -> Void)?
    /// Called (on a background task) when a take's lyrics are ready.
    public var onLyrics: (@Sendable (String, Lyrics) -> Void)?
    /// Lyrics for singing takes; nil = no transcription (model not ready).
    public var transcriber: LyricTranscribing?
    /// The lyric brain to check new lyrics against (built from the whole library).
    public var catalog: (@Sendable () -> LyricIndex)?
    /// Takes written so far (thread-safe snapshot).
    public var takes: [TakeRecord] { exportQueue.sync { written } }
    private var written: [TakeRecord] = []
    /// Heavy work (analysis, MIDI, tuning, encoding) runs here so capture never waits on it.
    private let exportQueue = DispatchQueue(label: "io.bluegum.hotmic.export", qos: .utility)
    /// Session position up to which new phrases are ignored (e.g. while a take preview plays).
    /// Atomics, so the drain queue never waits on the export queue.
    private let mutedUntil = AtomicU64(0)
    private let lastPosition = AtomicU64(0)
    /// Where rolling scratch audio lives: a cache folder, never the synced library.
    public static var scratchRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.bluegum.hotmic/scratch", isDirectory: true)
    }

    /// Removes scratch left behind by a crash (call at launch, before any session starts).
    public static func sweepOrphanedScratch() {
        try? FileManager.default.removeItem(at: scratchRoot)
    }

    private let scratch: ScratchStore
    private let detector: SingingDetector
    private let assembler: LiveTakeAssembler
    private var exporter: TakeExporter
    private let route: () -> String
    private let folder: URL
    private let sampleRate: Double
    private var pending: [Task<Void, Never>] = []
    private let pendingLock = NSLock()
    private var musicScratch: [Float] = []
    /// Everything transcribed so far this session: the hint for the next take's transcription.
    private var sessionLyrics = ""

    /// Jam mode: no DAW, one mic hearing instrument + voice. Every active stretch goes to the
    /// judge (JamJudge keeps anything musical), pauses up to 6 s stay inside one take.
    public let jam: Bool

    public init(folder: URL, sampleRate: Double, sessionStart: Date, daw: String, jam: Bool = false,
                route: @escaping () -> String = { "unknown" }) throws {
        self.jam = jam
        scratch = try ScratchStore(directory: Self.scratchRoot.appendingPathComponent(UUID().uuidString, isDirectory: true),
                                   sampleRate: sampleRate)
        detector = SingingDetector(sampleRate: sampleRate)
        var slicer = TakeSlicer(sampleRate: sampleRate)
        if jam { slicer.mergeGap = 6 }
        assembler = LiveTakeAssembler(slicer: slicer)
        exporter = TakeExporter(folder: folder, sampleRate: sampleRate, sessionStart: sessionStart, daw: daw)
        exporter.jam = jam
        self.route = route
        self.folder = folder
        self.sampleRate = sampleRate
        detector.onSegment = { [weak self] in self?.review($0) }
        if jam {
            detector.tuning.detectBeatbox = false   // strums are onsets, not beatbox
            judge = JamJudge()
            detector.emitCandidates = true
        }
    }

    /// Beatbox takes (drum MIDI). Off in the app for V1.
    public var beatboxEnabled: Bool {
        get { detector.tuning.detectBeatbox }
        set { detector.tuning.detectBeatbox = newValue && !jam }
    }

    /// Final say on each phrase (Apple's classifier in the app). Default: trust the pitch detector.
    public var judge: PhraseJudging = PitchOnlyJudge() {
        didSet { detector.emitCandidates = jam || !(judge is PitchOnlyJudge) }
    }

    /// Ignore anything detected for the next `seconds` — Hot Mic's own preview playback on
    /// speakers must never become a take. Call from any thread.
    public func muteDetection(for seconds: Double) {
        let until = lastPosition.value + UInt64(max(0, seconds) * sampleRate)
        if until > mutedUntil.value { mutedUntil.value = until }
    }

    private func review(_ segment: SingingSegment) {
        if segment.start >= 0, UInt64(segment.start) <= mutedUntil.value, mutedUntil.value > 0 { return }
        let samples = (try? scratch.read(from: segment.start, to: segment.end).voice) ?? []
        let verdict = judge.judge(samples, sampleRate: sampleRate, detected: segment.kind)
        HotMicLog.write(String(format: "phrase %.1f–%.1f s heard as %@ → %@", Double(segment.start) / sampleRate,
                               Double(segment.end) / sampleRate, "\(segment.kind)", verdict.map { "\($0)" } ?? "dropped"))
        guard let kind = verdict else { return }
        var accepted = segment
        accepted.kind = kind
        assembler.add(accepted)
    }

    public var options: ExportOptions {
        get { exporter.options }
        set { exporter.options = newValue }
    }

    public var referenceContainsVoice: () -> Bool {
        get { exporter.referenceContainsVoice }
        set { exporter.referenceContainsVoice = newValue }
    }

    /// Set for a phone singer's pipeline: their name lands in each take's file name and sidecar.
    public var singer: String? {
        get { exporter.singer }
        set { exporter.singer = newValue }
    }

    /// Recording more into an existing session: takes land after what's already there.
    public var timeOffset: Double {
        get { exporter.timeOffset }
        set { exporter.timeOffset = newValue }
    }

    public var positionAt: ((Int64) -> MusicalPosition?)? {
        get { exporter.positionAt }
        set { exporter.positionAt = newValue }
    }

    public func consume(voice: UnsafeBufferPointer<Float>, mix: UnsafeBufferPointer<Float>, frames: Int, position: Int64) {
        do {
            try scratch.append(voice: voice, mix: mix, frames: frames)
            // The music alone (mix minus voice) lets the detector predict leftover bleed.
            if musicScratch.count < frames { musicScratch = [Float](repeating: 0, count: frames) }
            for i in 0..<frames { musicScratch[i] = 0.5 * (mix[2 * i] + mix[2 * i + 1]) - voice[i] }
            musicScratch.withUnsafeBufferPointer { music in
                detector.feed(UnsafeBufferPointer(rebasing: voice[0..<frames]),
                              reference: UnsafeBufferPointer(rebasing: music[0..<frames]))
            }
            lastPosition.value = UInt64(max(0, position + Int64(frames)))
            try export(assembler.advance(to: position + Int64(frames), openPhraseStart: detector.openPhraseStart))
        } catch {
            HotMicLog.write("pipeline error: \(error)")
        }
    }

    /// Session end: close the last phrase, export what's pending, drop scratch audio.
    public func finish() throws {
        HotMicLog.write("session finishing: flushing the open phrase")
        defer {
            exportQueue.sync {}       // every take written before the session files close
            try? scratch.discard()
        }
        detector.flush()
        try export(assembler.flush())
    }

    /// The session never got going (e.g. its files couldn't be created): drop scratch audio now.
    public func abandon() { try? scratch.discard() }

    /// Waits for in-flight transcriptions (tests, and app quit).
    public func waitForLyrics() async {
        waitForExports()
        let tasks = pendingLock.withLock { pending }
        for task in tasks { await task.value }
    }

    /// Waits for queued exports (tests).
    public func waitForExports() { exportQueue.sync {} }

    /// Copies each take out of scratch here (drain queue), then writes it on the export queue.
    private func export(_ ranges: [TakeRange]) throws {
        let exporter = self.exporter, route = self.route()
        var firstError: Error?
        defer { if let firstError { HotMicLog.write("take snapshot failed: \(firstError)") } }
        for range in ranges {
            // One unreadable take must not throw away the others in the batch.
            let snapshot: TakeExporter.Snapshot?
            do { snapshot = try exporter.snapshot(range, from: scratch) } catch { firstError = firstError ?? error; continue }
            guard let snapshot else { HotMicLog.write("take \(range.start)–\(range.end) skipped: no audio left in scratch"); continue }
            exportQueue.async { [weak self] in
                do {
                    let (record, voice) = try exporter.write(snapshot, route: route)
                    HotMicLog.write(String(format: "take written: %@ (%.1f s, %@)", record.id, record.durationSeconds, record.kind ?? "?"))
                    self?.didWrite(record, voice: voice)
                } catch {
                    HotMicLog.write("take export failed: \(error)")
                }
            }
        }
    }

    /// Export queue.
    private func didWrite(_ record: TakeRecord, voice: [Float]) {
        written.append(record)
        onTake?(record)
        guard let transcriber, record.kind != SingingSegment.Kind.beatbox.rawValue else { return }
        let (folder, rate, id, onLyrics, catalog) = (folder, sampleRate, record.id, onLyrics, catalog)
        let sameSession = Set(written.map(\.id))   // earlier passes of this song = versions, not repeats
        let task = Task.detached(priority: .utility) { [weak self] in
            do {
                let hint = self?.pendingLock.withLock { self?.sessionLyrics }
                let lyrics = try await transcriber.transcribe(voice, sampleRate: rate, hint: hint ?? nil)
                HotMicLog.write("lyrics for \(id): \(lyrics.text.count) characters")
                guard !lyrics.text.isEmpty else { return }
                self?.pendingLock.withLock { self?.sessionLyrics += " " + lyrics.text }
                let echoes = catalog?().echoes(of: lyrics.text, excluding: sameSession.union([id]))
                    .map { EchoNote(line: $0.line, from: $0.title, matchedLine: $0.matchedLine) } ?? []
                try LyricSheet.attach(lyrics, echoes: echoes, toTake: id, in: folder)
                onLyrics?(id, lyrics)
            } catch {
                HotMicLog.write("transcription failed for \(id): \(error)")
            }
        }
        pendingLock.lock(); pending.append(task); pendingLock.unlock()
    }
}
