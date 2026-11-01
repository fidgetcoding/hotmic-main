import AVFoundation
import SoundAnalysis

/// Final say on a candidate phrase: is it a musical idea worth a take, and what kind?
/// Returns nil to drop it (talking, coughs, room noise).
public protocol PhraseJudging {
    func judge(_ samples: [Float], sampleRate: Double, detected: SingingSegment.Kind) -> SingingSegment.Kind?
}

/// Without a classifier: trust the pitch detector (held notes = singing, hits = beatbox).
public struct PitchOnlyJudge: PhraseJudging {
    public init() {}
    public func judge(_ samples: [Float], sampleRate: Double, detected: SingingSegment.Kind) -> SingingSegment.Kind? {
        detected == .other ? nil : detected
    }
}

/// Apple's on-device sound classifier (SoundAnalysis, 303 labels incl. singing, humming, rapping,
/// speech). Catches freestyle rap the held-note detector misses, and vetoes talking it lets through.
public final class AppleVoiceJudge: PhraseJudging {
    public struct Scores: Equatable, Sendable {
        public var singing: Double = 0, humming: Double = 0, rapping: Double = 0, speech: Double = 0
        /// Any instrument or "music" at all.
        public var music: Double = 0
        public var whisper: Double = 0
        /// Drum hits with no pitched instrument: how beatboxing scores (Apple has no beatbox label).
        public var drums: Double = 0, pitched: Double = 0
        /// A named instrument (guitar, piano, horns...), not the generic "music" label, which rap scores high on.
        public var instrument: Double = 0
    }

    public init() {}

    public func judge(_ samples: [Float], sampleRate: Double, detected: SingingSegment.Kind) -> SingingSegment.Kind? {
        guard let s = scores(samples, sampleRate: sampleRate) else { return PitchOnlyJudge().judge(samples, sampleRate: sampleRate, detected: detected) }
        // Whispered consonants look like beatbox hits to the onset detector; the classifier knows better.
        if detected == .beatbox { return s.whisper >= 0.3 && s.whisper >= s.speech ? .whisper : .beatbox }
        let musical = max(s.singing, s.humming, s.rapping)
        if musical >= 0.3, musical >= s.speech {
            return s.rapping > max(s.singing, s.humming) ? .rap : .singing
        }
        if s.whisper >= 0.3, s.whisper >= s.speech { return .whisper }  // whispering a line to yourself
        if detected == .singing, s.speech < 0.5 { return .singing }  // clear held notes, classifier unsure
        return nil
    }

    /// Mean confidence per label group over the phrase.
    public func scores(_ samples: [Float], sampleRate: Double) -> Scores? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        request.windowDuration = CMTime(seconds: 1.0, preferredTimescale: 48_000)
        request.overlapFactor = 0.5

        let collector = Collector()
        let analyzer = SNAudioStreamAnalyzer(format: format)
        guard (try? analyzer.add(request, withObserver: collector)) != nil else { return nil }
        analyzer.analyze(buffer, atAudioFramePosition: 0)
        analyzer.completeAnalysis()
        return collector.average()
    }

    private final class Collector: NSObject, SNResultsObserving {
        private var sums = Scores()
        private var windows = 0

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            func c(_ id: String) -> Double { result.classification(forIdentifier: id)?.confidence ?? 0 }
            sums.singing += max(c("singing"), c("choir_singing"), c("yodeling"))
            sums.humming += max(c("humming"), c("whistling"))
            sums.rapping += c("rapping")
            sums.speech += max(c("speech"), c("shout"))
            sums.whisper += c("whispering")
            sums.music += Self.musicLabels.map(c).max() ?? 0
            sums.drums += Self.drumLabels.map(c).max() ?? 0
            sums.pitched += Self.musicLabels.filter { !Self.drumLabels.contains($0) }.map(c).max() ?? 0
            sums.instrument += Self.musicLabels.filter { $0 != "music" && !Self.drumLabels.contains($0) }.map(c).max() ?? 0
            windows += 1
        }

        func average() -> Scores? {
            guard windows > 0 else { return nil }
            let n = Double(windows)
            return Scores(singing: sums.singing / n, humming: sums.humming / n, rapping: sums.rapping / n,
                          speech: sums.speech / n, music: sums.music / n, whisper: sums.whisper / n,
                          drums: sums.drums / n, pitched: sums.pitched / n, instrument: sums.instrument / n)
        }

        static let drumLabels = ["percussion", "drum_kit", "drum", "snare_drum", "bass_drum", "thump_thud"]

        static let musicLabels = [
            "music", "plucked_string_instrument", "guitar", "electric_guitar", "bass_guitar", "acoustic_guitar",
            "steel_guitar_slide_guitar", "guitar_tapping", "guitar_strum", "banjo", "sitar", "mandolin", "zither",
            "ukulele", "keyboard_musical", "piano", "electric_piano", "organ", "electronic_organ", "hammond_organ",
            "synthesizer", "harpsichord", "percussion", "drum_kit", "drum", "snare_drum", "bass_drum", "tabla",
            "mallet_percussion", "marimba_xylophone", "glockenspiel", "vibraphone", "brass_instrument", "trumpet",
            "bowed_string_instrument", "violin_fiddle", "cello", "double_bass", "wind_instrument", "flute",
            "saxophone", "bassoon", "harp", "harmonica", "accordion",
        ]
    }
}

/// Jam mode's judge: keep anything musical (playing, singing, humming, rapping, or all at once)
/// and drop stretches that are mostly talking between songs.
public final class JamJudge: PhraseJudging {
    private let classifier = AppleVoiceJudge()
    /// Beat mode: the beat is Hot Mic's own playback (the echo reference), never your playing. Its bleed
    /// into the mic made rap takes "playing" with chords (Nate 2026-10-13 late test), so only your voice counts.
    public let beat: Bool
    public init(beat: Bool = false) { self.beat = beat }

    public func judge(_ samples: [Float], sampleRate: Double, detected: SingingSegment.Kind) -> SingingSegment.Kind? {
        guard let s = classifier.scores(samples, sampleRate: sampleRate) else { return beat ? .rap : .playing }  // no classifier: keep it
        return Self.decide(s, beat: beat)
    }

    /// Freestyle keeps anything voiced (Nate 2026-10-12): rap, whispers and mumbles score like talk to
    /// the classifier, and a lost idea is worse than a kept aside. Only silence and noise are dropped.
    static func decide(_ s: AppleVoiceJudge.Scores, beat: Bool = false) -> SingingSegment.Kind? {
        let voice = max(s.singing, s.humming, s.rapping)
        if beat {
            if voice >= 0.15, voice >= s.speech * 0.5 { return s.rapping > max(s.singing, s.humming) ? .rap : .singing }
            if s.whisper >= 0.15, s.whisper >= s.speech * 0.5 { return .whisper }
            return s.speech >= 0.1 || voice >= 0.1 || s.music >= 0.25 ? .rap : nil
        }
        // Beatboxing: drum hits and no pitched instrument (Nate 2026-10-13: "not registering beatboxing").
        if s.drums >= 0.2, s.drums > s.pitched * 1.5, s.drums >= voice { return .beatbox }
        // Rapping and talking alone score "music" 0.3–0.4 too (Nate's 2026-10-13 test on the MacBook mic:
        // every bar became "playing"), so playing over talk needs a named instrument: a voice scores ≤ 0.23, strums 0.9.
        if s.music >= 0.25, s.music >= s.speech * 0.6, s.instrument >= 0.35 || (s.speech < 0.15 && voice < 0.3) { return .playing }
        if voice >= 0.3, voice >= s.speech { return s.rapping > max(s.singing, s.humming) ? .rap : .singing }
        if s.whisper >= 0.15, s.whisper >= s.speech * 0.5 { return .whisper }
        if s.speech >= 0.15 || voice >= 0.15 { return .rap }          // talk-like delivery: bars, spoken word, asides
        if s.whisper >= 0.1 { return .whisper }
        return nil
    }
}
