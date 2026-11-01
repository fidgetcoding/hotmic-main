import Capture
import Detection
import Enrichment
import Foundation
import Timeline

/// Sidecar written next to every take (spec: Output format). Timeline/enrichment fields fill in later.
public struct TakeRecord: Codable, Equatable, Sendable {
    public var id: String
    public var createdAt: Date
    public var daw: String
    public var sessionStartSeconds: Double
    public var durationSeconds: Double
    public var confidence: Float
    public var route: String
    public var files: [String: String]
    /// Where the song was when the take started (nil when no DAW clock was running).
    public var position: MusicalPosition?
    /// Key of the music around the take (from the session audio, not the hum).
    public var key: MusicalKey?
    public var notes: Int?
    /// Section the take started in, e.g. "B" — inferred from the audio unless the DAW names it.
    public var section: String?
    public var sectionSource: String?
    /// "singing" or "beatbox".
    public var kind: String?
    /// Filled in asynchronously after the take is written (transcription takes a few seconds).
    public var lyrics: Lyrics?
    /// Lines in this take you've sung or written before, and where.
    public var echoes: [EchoNote]?
    /// Tempo heard in the take when no DAW clock was running (jam mode, or DAW stopped).
    public var tempo: TempoEstimator.Result?
    /// Chords under the take, seconds from the start of the take file.
    public var chords: [ChordSpan]?
    /// Seconds of lead-in before the first sung note (the position stamp is taken there).
    public var padding: Double?
    /// The take's notes (seconds from the start of the take files), for per-line / per-bar MIDI.
    public var midiNotes: [Note]?
    /// Who sang it when it came from a phone in the session (nil = the host's own mic).
    public var singer: String?
}

public struct EchoNote: Codable, Equatable, Sendable {
    public var line: String
    public var from: String
    public var matchedLine: String
}

public struct ExportOptions: Sendable, Equatable {
    public var keyAndSections = true
    public var voiceToMIDI = true
    public var tunedTakes = true
    public var tuneMode: Tuner.Mode = .natural
    /// Level every saved file to a playable volume with a peak limiter.
    public var normalizeLoudness = true
    public init() {}
    public static let captureOnly: ExportOptions = { var o = ExportOptions(); o.keyAndSections = false; o.voiceToMIDI = false; o.tunedTakes = false; return o }()
}

/// Cuts a take out of the scratch store and writes `<name>__voice.m4a`, `<name>__mix.m4a`, `<name>.json`.
public struct TakeExporter {
    public let folder: URL
    public let sampleRate: Double
    public let sessionStart: Date
    public let daw: String
    /// Session output frame → musical position, from the DAW's MIDI clock.
    public var positionAt: ((Int64) -> MusicalPosition?)?
    /// Enrichment switches (all on by default).
    public var options = ExportOptions()
    /// True while the DAW plays the singer back (input monitoring): the mix already holds the
    /// voice once, so "music only" must not subtract it.
    public var referenceContainsVoice: () -> Bool = { false }
    /// Jam mode: the "voice" track is the whole mic (instrument + voice), so chords, key and
    /// tempo come from it and there's no tuned take (you can't auto-tune a guitar).
    public var jam = false
    /// Recording more into an existing session: seconds already recorded before this run.
    public var timeOffset: Double = 0
    /// Takes from a phone in the session: the singer's name goes in the file name and sidecar.
    public var singer: String?
    private let createdBox = CreatedFiles()
    private var createdFiles: [URL] {
        get { createdBox.urls }
        nonmutating set { createdBox.urls = newValue }
    }

    /// Letters, digits and dashes: names come from other people's phones.
    public static func fileSafe(_ name: String) -> String {
        let mapped = String(name.prefix(24).map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let collapsed = mapped.split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "guest" : collapsed
    }

    public init(folder: URL, sampleRate: Double, sessionStart: Date, daw: String) {
        self.folder = folder
        self.sampleRate = sampleRate
        self.sessionStart = sessionStart
        self.daw = daw
    }

    @discardableResult
    public func export(_ take: TakeRange, from scratch: ScratchStore, route: String) throws -> TakeRecord? {
        try exportWithVoice(take, from: scratch, route: route)?.record
    }

    /// Everything a take needs, copied out of the scratch store (cheap; safe to hand to another queue).
    public struct Snapshot: Sendable {
        public var take: TakeRange
        public var voice: [Float]
        public var mix: [Float]
        public var keyContext: [Float]         // mono music, up to 30 s into and through the take
        public var structureContext: [Float]   // mono music, up to 3 min ending with the take
        public var structureStart: Int64
        public var takeMusic: [Float] = []    // mono music under the take itself (chords, tempo)
    }

    /// Copy the take out of scratch. Clamps to what scratch still holds, so a take longer than the
    /// retention window keeps honest timestamps instead of claiming audio it no longer has.
    public func snapshot(_ take: TakeRange, from scratch: ScratchStore) throws -> Snapshot? {
        var take = take
        let oldest = scratch.oldestRetained
        if take.start < oldest {
            let lost = Double(oldest - take.start) / sampleRate
            take.padding = max(0, take.padding - lost)
            take.start = oldest
        }
        let audio = try scratch.read(from: take.start, to: take.end)
        guard !audio.voice.isEmpty else { return nil }
        // Music only: mix = song + voice in both channels, so song = L + R − 2·voice. The key comes
        // from the band, never from an off-key hum.
        let monitored = referenceContainsVoice()
        func music(_ a: (voice: [Float], mix: [Float])) -> [Float] {
            var out = [Float](repeating: 0, count: a.voice.count)
            for i in out.indices {
                let left = a.mix[2 * i], right = a.mix[2 * i + 1]
                out[i] = monitored ? left + right : left + right - 2 * a.voice[i]
            }
            return out
        }
        let keyContext = options.keyAndSections ? music(try scratch.read(from: take.start - Int64(30 * sampleRate), to: take.end)) : []
        let structureStart = max(oldest, take.start - Int64(180 * sampleRate))
        let structureContext = options.keyAndSections ? music(try scratch.read(from: structureStart, to: take.end)) : []
        var snapshot = Snapshot(take: take, voice: audio.voice, mix: audio.mix, keyContext: jam ? audio.voice : keyContext,
                                structureContext: jam ? [] : structureContext, structureStart: structureStart)
        snapshot.takeMusic = jam ? audio.voice : (options.keyAndSections ? music(audio) : [])
        return snapshot
    }

    /// Same as `export`, also handing back the take's voice samples for async enrichment (lyrics).
    public func exportWithVoice(_ take: TakeRange, from scratch: ScratchStore, route: String) throws -> (record: TakeRecord, voice: [Float])? {
        guard let snapshot = try snapshot(take, from: scratch) else { return nil }
        return try write(snapshot, route: route)
    }

    /// The heavy part: analysis, MIDI, tuning, encoding, sidecar. Run it off the capture path.
    public func write(_ snapshot: Snapshot, route: String) throws -> (record: TakeRecord, voice: [Float]) {
        createdFiles = []
        do {
            return try writeFiles(snapshot, route: route)
        } catch {
            // No half-written takes: remove whatever this take already wrote, then report.
            for url in createdFiles { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    private func writeFiles(_ snapshot: Snapshot, route: String) throws -> (record: TakeRecord, voice: [Float]) {
        let take = snapshot.take
        let audio = (voice: snapshot.voice, mix: snapshot.mix)
        let startSeconds = Double(take.start) / sampleRate + timeOffset
        let created = sessionStart.addingTimeInterval(Double(take.start) / sampleRate)
        // Stamp the first sung note (after the padding), not the padded start.
        let position = positionAt?(take.start + Int64(min(take.padding, Double(take.end - take.start) / sampleRate) * sampleRate))
        // Key from up to 30 s of music leading into and through the take.
        // Jam: the "music" is the mic itself, so key, tempo and chords only come from a take where an
        // instrument played. Talk and rap gave Bb minor, 140 bpm and chords (Nate 2026-10-14: "if all I've done is say a word").
        let musical = !jam || take.kind == .playing
        let key = options.keyAndSections && musical ? KeyDetector().detect(snapshot.keyContext, sampleRate: sampleRate) : nil
        let beatbox = take.kind == .beatbox
        let dawTempo = position.flatMap { $0.playing ? $0.tempo : nil }
        let tempo = dawTempo == nil && musical && !snapshot.takeMusic.isEmpty ? TempoEstimator().estimate(snapshot.takeMusic, sampleRate: sampleRate) : nil
        let chords = snapshot.takeMusic.isEmpty || !musical ? [] : ChordRecognizer().chords(snapshot.takeMusic, sampleRate: sampleRate)
        let notes: [Note]
        if beatbox || take.kind == .rap || take.kind == .whisper || !options.voiceToMIDI {
            notes = []
        } else if jam && take.kind == .playing {
            // Instrument + voice on one mic: every note, chords included (Basic Pitch).
            notes = (try? PolyphonicTranscriber.shared?.notes(from: audio.voice, sampleRate: sampleRate)) ?? []
        } else {
            notes = MelodyTranscriber().notes(from: audio.voice, sampleRate: sampleRate, key: key)
        }
        let drums = beatbox && options.voiceToMIDI ? DrumTranscriber().hits(from: audio.voice, sampleRate: sampleRate) : []

        // Section guess from up to 3 minutes of music ending with the take.
        let takeAt = Double(take.start - snapshot.structureStart) / sampleRate + take.padding
        let section = options.keyAndSections ? StructureAnalyzer().sections(snapshot.structureContext, sampleRate: sampleRate)
            .first { $0.start <= takeAt && takeAt < $0.end }?.label : nil

        var name = "\(Self.stamp.string(from: created))_\(daw.replacingOccurrences(of: " ", with: "-"))"
        if let position, position.playing { name += "_bar-\(position.bar)_\(Int(position.tempo.rounded()))bpm" }
        else if let tempo, tempo.confidence > 0.2 { name += "_\(Int(tempo.bpm.rounded()))bpm" }
        if let key, !beatbox { name += "_\(key.short)" }
        if beatbox { name += "_beatbox" }
        if take.kind == .rap { name += "_rap" }
        if take.kind == .whisper { name += "_whisper" }
        if let singer { name += "_by-\(Self.fileSafe(singer))" }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var unique = name, n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(unique).json").path)
                || FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(unique)__voice.m4a").path) {
            unique = "\(name)-\(n)"; n += 1
        }
        name = unique
        let voiceName = "\(name)__voice.m4a", mixName = "\(name)__mix.m4a"
        try write(audio.voice, channels: 1, bitRate: 96_000, to: voiceName)
        try write(audio.mix, channels: 2, bitRate: 192_000, to: mixName)
        var files = ["voice": voiceName, "mix": mixName]
        let bpm = dawTempo ?? tempo?.bpm ?? position?.tempo ?? 120
        if options.tunedTakes, !jam, !notes.isEmpty, key != nil {
            let tunedName = "\(name)__tuned.m4a"
            try write(Tuner(mode: options.tuneMode).tune(audio.voice, sampleRate: sampleRate, notes: notes), channels: 1, bitRate: 96_000, to: tunedName)
            files["tuned"] = tunedName
        }
        if !notes.isEmpty {
            let midiName = "\(name).mid"
            createdFiles.append(folder.appendingPathComponent(midiName))
            try MIDIFileWriter.data(notes: notes, tempo: bpm, beatsPerBar: position?.beatsPerBar ?? 4, trackName: name)
                .write(to: folder.appendingPathComponent(midiName))
            files["midi"] = midiName
        }
        if !drums.isEmpty {
            let midiName = "\(name)__drums.mid"
            createdFiles.append(folder.appendingPathComponent(midiName))
            try MIDIFileWriter.drums(drums, tempo: bpm, beatsPerBar: position?.beatsPerBar ?? 4, trackName: name)
                .write(to: folder.appendingPathComponent(midiName))
            files["drums"] = midiName
        }

        var record = TakeRecord(id: name, createdAt: created, daw: daw, sessionStartSeconds: startSeconds,
                                durationSeconds: Double(audio.voice.count) / sampleRate,
                                confidence: take.confidence, route: route,
                                files: files, position: position, key: key, notes: notes.count,
                                section: section, sectionSource: section == nil ? nil : "audio-guess",
                                kind: take.kind.rawValue)
        record.tempo = tempo
        record.padding = take.padding
        record.singer = singer
        record.midiNotes = notes.isEmpty ? nil : notes
        record.chords = chords.isEmpty || chords.allSatisfy({ $0.name == "N" }) ? nil : chords
        try LyricSheet.encoder.encode(record).write(to: folder.appendingPathComponent("\(name).json"), options: .atomic)
        return (record, audio.voice)
    }

    private func write(_ samples: [Float], channels: Int, bitRate: Int, to name: String) throws {
        createdFiles.append(folder.appendingPathComponent(name))
        let samples = options.normalizeLoudness ? Loudness().normalize(samples, channels: channels, sampleRate: sampleRate) : samples
        let writer = try AACFileWriter(url: folder.appendingPathComponent(name), sampleRate: sampleRate,
                                       channels: channels, bitRate: bitRate)
        try samples.withUnsafeBufferPointer { try writer.append(interleaved: $0, frames: samples.count / channels) }
        try writer.finish()
    }

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f
    }()
}

/// Files a take export has created so far (reference box so the struct exporter can track them).
final class CreatedFiles: @unchecked Sendable { var urls: [URL] = [] }
