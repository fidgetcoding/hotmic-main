import AVFoundation
import Enrichment
import Foundation
import WhisperKit

/// Lyrics via WhisperKit (Whisper on Core ML). The model downloads once on first use, then runs
/// fully on-device. Default: large-v3 turbo, uncompressed (~1.6 GB): the compressed 626 MB build
/// decodes nothing on short sung clips (bench, 2026-10-28).
public actor WhisperTranscriber: LyricTranscribing {
    public static let defaultModel = "large-v3-v20240930_turbo"

    /// Where the app keeps the model. WhisperKit's own default is ~/Documents/huggingface, which on a clean Mac means
    /// a permission prompt about Documents for a cache nobody should see. A copy already there is used as it is.
    public static func modelFolder(model: String = defaultModel, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let old = home.appendingPathComponent("Documents/huggingface", isDirectory: true)
        if FileManager.default.fileExists(atPath: old.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-\(model)").path) { return old }
        return home.appendingPathComponent("Library/Application Support/Hot Mic/Models", isDirectory: true)
    }

    /// Decoding switches (the bench flips these to find what drops a take's words).
    public struct Tuning: Sendable {
        public var prompt = true
        public var vadChunking = true
        public var noSpeechThreshold: Float = 0.85
        public var language: String? = nil
        public var temperature: Float = 0
        public var debug = false
        public var timestamps = true
        /// Long takes are decoded in pieces no longer than this, cut at quiet spots.
        public var pieceSeconds = 25.0
        /// How far back from a piece's end the quiet spot may be.
        public var searchSeconds = 8.0
        /// Feed the session's earlier lyrics to the decoder as a hint.
        public var sessionHint = true
        /// Retries at a higher temperature when a decode fails Whisper's own quality checks.
        public var fallbacks = 5
        public var logProbThreshold: Float? = -1
        public var compressionThreshold: Float? = 2.4
        /// Take Whisper's loops out of a segment instead of dropping the whole segment.
        public var loopFix = false
        /// Spread collapsed word times out over the piece.
        public var spreadTimes = false
        /// Try a failed piece again other ways.
        public var retries = false
        /// A piece with fewer words than this per second of voiced sound counts as failed.
        public var minWordsPerVoicedSecond = 0.5
        public init() {}
    }

    private let model: String
    private let downloadBase: URL?
    private let tuning: Tuning
    private var pipe: WhisperKit?
    private var loading: Task<WhisperKit, Error>?
    private var tail: Task<Void, Never>?   // serializes jobs: one WhisperKit instance, one decode at a time

    public init(model: String = defaultModel, downloadBase: URL? = nil, tuning: Tuning = Tuning()) {
        self.model = model
        self.downloadBase = downloadBase
        self.tuning = tuning
    }

    /// Load (and download if needed) ahead of the first take so lyrics appear quickly.
    /// Loads once, even if the launch warm-up and the first take ask at the same time.
    public func prepare() async throws {
        _ = try await loaded()
    }

    private func loaded() async throws -> WhisperKit {
        if let pipe { return pipe }
        if loading == nil {
            let (model, base) = (model, downloadBase)
            loading = Task {
                try await WhisperKit(WhisperKitConfig(model: model, downloadBase: base,
                                                      verbose: false, prewarm: true, load: true, download: true))
            }
        }
        do {
            let loadedPipe = try await loading!.value
            pipe = loadedPipe
            return loadedPipe
        } catch {
            loading = nil   // allow a retry (e.g. first-run download failed offline)
            throw error
        }
    }

    public func transcribe(_ samples: [Float], sampleRate: Double) async throws -> Lyrics {
        try await transcribe(samples, sampleRate: sampleRate, hint: nil)
    }

    public func transcribe(_ samples: [Float], sampleRate: Double, hint: String?) async throws -> Lyrics {
        // Queue behind any job already running on this instance.
        let previous = tail
        let job = Task { () -> Result<Lyrics, Error> in
            await previous?.value
            do { return .success(try await self.run(samples, sampleRate: sampleRate, hint: hint)) } catch { return .failure(error) }
        }
        tail = Task { _ = await job.value }
        return try await job.value.get()
    }

    /// Written in the register we want back: lowercase, contracted, slang and ad-libs kept as said.
    static let slangRegister = "yeah uh, i'm finna, tryna, ion even, lil bro, ain't, y'all, gon', bruh, skrrt, ayy, whoa, nah fr,"

    private func run(_ samples: [Float], sampleRate: Double, hint: String?) async throws -> Lyrics {
        let pipe = try await loaded()
        // Level first: whispers and mumbles sit ~30 dB down, and WhisperKit's voice-activity
        // chunker (energy ≥ 0.02) would otherwise throw them away before decoding.
        let levelled = Loudness().normalize(samples, channels: 1, sampleRate: sampleRate)
        let audio = try Self.resample(levelled, from: sampleRate, to: 16_000)
        var options = DecodingOptions(task: .transcribe, language: tuning.language, temperature: tuning.temperature, wordTimestamps: true,
                                      suppressBlank: true, chunkingStrategy: tuning.vadChunking ? .vad : ChunkingStrategy.none)
        // Takes are already judged to be sung/whispered ideas: only skip a window when Whisper is
        // very sure nothing's there (default 0.6 drops breathy lines).
        options.noSpeechThreshold = tuning.noSpeechThreshold
        options.temperatureFallbackCount = tuning.fallbacks
        options.logProbThreshold = tuning.logProbThreshold
        options.compressionRatioThreshold = tuning.compressionThreshold
        if !tuning.timestamps { options.withoutTimestamps = true; options.wordTimestamps = false }
        // Prompt = how rappers and singers actually talk (keeps slang, contractions and ad-libs as
        // said instead of "correcting" them), then this session's own recent lyrics.
        if tuning.prompt, let tokenizer = pipe.tokenizer {
            let session = !tuning.sessionHint || (hint ?? "").isEmpty ? "" : " " + String(hint!.suffix(200))
            options.promptTokens = tokenizer.encode(text: " " + Self.slangRegister + session)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        // Long takes go in short pieces cut at quiet spots, each decoded on its own: one pass over a
        // 10-minute take skips minutes, collapses word timings and loops.
        var texts: [String] = [], words: [Lyrics.Word] = []
        for piece in Lyrics.pieces(audio, sampleRate: 16_000, maxSeconds: tuning.pieceSeconds, searchSeconds: tuning.searchSeconds) {
            let got = try await decode(piece, of: audio, options: options, pipe: pipe)
            if !got.text.isEmpty { texts.append(got.text) }
            words += got.words
        }
        return Lyrics(text: texts.joined(separator: " "), words: words)
    }

    /// One piece. When Whisper gives up on it (nothing back, or far too few words for how much sound there is:
    /// it goes straight to end-of-text on some sung clips, or loops), it gets more tries before it counts as empty.
    private func decode(_ piece: Range<Int>, of audio: [Float], options: DecodingOptions, pipe: WhisperKit) async throws -> Lyrics {
        var best = try await attempt(piece, of: audio, options: options, pipe: pipe)
        guard tuning.retries else { return best }
        let voiced = Lyrics.voicedSeconds(audio[piece], sampleRate: 16_000)
        func enough(_ l: Lyrics) -> Bool { voiced < 2 || Double(l.words.count) >= tuning.minWordsPerVoicedSecond * voiced }
        guard !enough(best) else { return best }
        // Other ways in: without the hint, a little later in the audio, and sampling instead of the greedy path.
        var plain = options
        plain.promptTokens = nil
        var warm = plain
        warm.temperature = 0.4
        let late = (piece.lowerBound + 16_000)..<piece.upperBound
        for (range, opts) in [(piece, plain), (late, plain), (piece, warm)] where range.count > 16_000 {
            let again = try await attempt(range, of: audio, options: opts, pipe: pipe)
            if tuning.debug { print("  retry: \(best.words.count) words before, \(again.words.count) now") }
            if again.words.count > best.words.count { best = again }
            if enough(best) { break }
        }
        return best
    }

    private func attempt(_ piece: Range<Int>, of audio: [Float], options: DecodingOptions, pipe: WhisperKit) async throws -> Lyrics {
        let offset = Double(piece.lowerBound) / 16_000
        let results = try await pipe.transcribe(audioArray: Array(audio[piece]), decodeOptions: options)
        if tuning.debug { print(String(format: "piece %.1f–%.1f s: %d result(s), %d segment(s)", offset, Double(piece.upperBound) / 16_000, results.count, results.flatMap(\.segments).count)) }
        var texts: [String] = [], words: [Lyrics.Word] = []
        for segment in results.flatMap(\.segments) {
            if tuning.debug { print(String(format: "  piece %.1f s  segment %.1f–%.1f  no-speech %.2f  logprob %.2f  \"%@\"",
                                           offset, segment.start, segment.end, segment.noSpeechProb, segment.avgLogprob, segment.text)) }
            var text = segment.text
                .replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)  // special tokens
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var kept = (segment.words ?? []).map {
                Lyrics.Word(text: $0.word.trimmingCharacters(in: .whitespaces), start: offset + Double($0.start), end: offset + Double($0.end))
            }.filter { !$0.text.isEmpty }
            if tuning.loopFix {
                let stay = Lyrics.withoutLoops(kept.map(\.text))
                if stay.count < kept.count {
                    kept = stay.map { kept[$0] }
                    text = kept.map(\.text).joined(separator: " ")
                }
            }
            guard !text.isEmpty, !Lyrics.isLoop(text) else { continue }
            texts.append(text)
            words += kept
        }
        if tuning.spreadTimes {
            words = Lyrics.spreadCollapsed(words, from: offset, to: Double(piece.upperBound) / 16_000)
        }
        return Lyrics(text: texts.joined(separator: " "), words: words)
    }

    /// Band-limited resample with AVAudioConverter (Whisper expects 16 kHz mono).
    static func resample(_ x: [Float], from inRate: Double, to outRate: Double) throws -> [Float] {
        guard inRate != outRate, !x.isEmpty else { return x }
        let inFormat = AVAudioFormat(standardFormatWithSampleRate: inRate, channels: 1)!
        let outFormat = AVAudioFormat(standardFormatWithSampleRate: outRate, channels: 1)!
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(x.count)) else { return x }
        input.frameLength = AVAudioFrameCount(x.count)
        x.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: x.count) }
        let capacity = AVAudioFrameCount(Double(x.count) * outRate / inRate) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return x }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
