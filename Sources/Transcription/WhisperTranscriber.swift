import AVFoundation
import Enrichment
import Foundation
import WhisperKit

/// Lyrics via WhisperKit (Whisper on Core ML). The model downloads once on first use, then runs
/// fully on-device. Default: large-v3 turbo, uncompressed (~1.6 GB): the compressed 626 MB build
/// decodes nothing on short sung clips (bench, 2026-10-28).
public actor WhisperTranscriber: LyricTranscribing {
    public static let defaultModel = "large-v3-v20240930_turbo"

    /// Decoding switches (the bench flips these to find what drops a take's words).
    public struct Tuning: Sendable {
        public var prompt = true
        public var vadChunking = true
        public var noSpeechThreshold: Float = 0.85
        public var language: String? = nil
        public var temperature: Float = 0
        public var debug = false
        public var timestamps = true
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
        if !tuning.timestamps { options.withoutTimestamps = true; options.wordTimestamps = false }
        // Prompt = how rappers and singers actually talk (keeps slang, contractions and ad-libs as
        // said instead of "correcting" them), then this session's own recent lyrics.
        if tuning.prompt, let tokenizer = pipe.tokenizer {
            let session = (hint ?? "").isEmpty ? "" : " " + String(hint!.suffix(200))
            options.promptTokens = tokenizer.encode(text: " " + Self.slangRegister + session)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        // Long takes go in ≤ 25 s pieces cut at quiet spots, each decoded on its own: one pass over a
        // 10-minute take skips minutes, collapses word timings and loops.
        var texts: [String] = [], words: [Lyrics.Word] = []
        for piece in Lyrics.pieces(audio, sampleRate: 16_000) {
            let offset = Double(piece.lowerBound) / 16_000
            let results = try await pipe.transcribe(audioArray: Array(audio[piece]), decodeOptions: options)
            if tuning.debug { print(String(format: "piece %.1f–%.1f s: %d result(s), %d segment(s)", offset, Double(piece.upperBound) / 16_000, results.count, results.flatMap(\.segments).count)) }
            for segment in results.flatMap(\.segments) {
                if tuning.debug { print(String(format: "  piece %.1f s  segment %.1f–%.1f  no-speech %.2f  logprob %.2f  \"%@\"",
                                               offset, segment.start, segment.end, segment.noSpeechProb, segment.avgLogprob, segment.text)) }
                let text = segment.text
                    .replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)  // special tokens
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, !Lyrics.isLoop(text) else { continue }
                texts.append(text)
                words += (segment.words ?? []).map {
                    Lyrics.Word(text: $0.word.trimmingCharacters(in: .whitespaces), start: offset + Double($0.start), end: offset + Double($0.end))
                }.filter { !$0.text.isEmpty }
            }
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
