import Foundation

/// A stretch of the session where someone sang or hummed. Frames are at the session sample rate.
public struct SingingSegment: Equatable, Sendable {
    public enum Kind: String, Sendable, Codable {
        case singing, beatbox, rap
        /// Jam mode: an instrument (usually with a voice over it).
        case playing
        /// A whispered idea (no pitch; the classifier hears whispering, not talking).
        case whisper
        /// Active phrase the pitch detector didn't recognize; only emitted as a candidate for a judge.
        case other
    }
    public var start: Int64
    public var end: Int64
    public var confidence: Float
    public var medianHz: Float
    public var kind: Kind = .singing
}

/// Streaming singing-vs-everything-else detector on the (echo-cancelled) voice stream.
///
/// Phrases = active regions split by ≥ 400 ms of quiet. A phrase counts as singing when it is
/// mostly voiced AND mostly *held notes*: pitch that stays within ±35 cents for ≥ 150 ms after
/// smoothing over one vibrato cycle. Speech glides between pitches; singing and humming hold them.
public final class SingingDetector {
    public struct Tuning: Sendable {
        public var minDuration: Double = 0.8          // s
        public var minVoicedRatio: Float = 0.55
        public var minHeldRatio: Float = 0.40
        public var holdCents: Float = 35
        public var holdFrames = 15                    // 150 ms
        public var vibratoFrames = 18                 // ~one 5.5 Hz cycle
        public var quietToSplit = 40                  // 400 ms
        public var activeAboveFloor: Float = 10       // dB over the floor (smoothed level)
        public var floorWindowFrames = 500            // 5 s of history: follows the song's quiet/loud sections
        public var floorPercentile = 0.2              // robust to transients; a 4 s phrase can't lift it
        /// Beatbox → drum takes. Off in V1 (Nate, 2026-09-27: "a bit overkill"); code kept for later.
        public var detectBeatbox = true
        public var beatboxMaxVoiced: Float = 0.35     // beatbox = mostly unvoiced…
        public var beatboxMinOnsetsPerSecond = 2.0    // …and made of hits
        public var onsetJump: Float = 12              // dB over the last 30 ms minimum
        public init() {}
    }

    public var onSegment: ((SingingSegment) -> Void)?
    /// Also emit non-musical-looking phrases as `.other` so a classifier can rescue rap/singing.
    public var emitCandidates = false
    /// Diagnostics: (smoothed level, floor, active) per 10 ms frame.
    var onFrame: ((Float, Float, Bool) -> Void)?

    private let sampleRate: Double
    private let factor: Int
    private let hop: Int                  // in decimated samples (10 ms)
    public var tuning: Tuning
    private var tracker: PitchTracker
    private var decimated: [Float] = []
    private var decimatedRef: [Float] = []    // session music, same timeline (optional)
    private var decimatedStart: Int64 = 0 // session frame of decimated[0]
    private var carry: [Float] = []
    private var refCarry: [Float] = []
    private var hasReference = false
    private var leakOffset: Float = -30       // voice-track level minus music level while nobody sings
    private var leakLearned = false
    private var activeRun = 0
    private var smoothedLevel: Float = -90
    private var floorHistory: [Float] = []        // smoothed levels, last `floorWindowFrames`
    private var floorCache: Float = -90
    private var floorAge = 0

    private var phrase: [PitchFrame] = []
    private var phraseOnsets = 0
    private var recentLevels: [Float] = []
    private var phraseStart: Int64 = 0
    private var quietRun = 0

    public init(sampleRate: Double, tuning: Tuning = Tuning()) {
        self.sampleRate = sampleRate
        self.tuning = tuning
        factor = max(1, Int((sampleRate / 16_000).rounded()))
        let rate = Float(sampleRate) / Float(factor)
        hop = Int(rate / 100)
        tracker = PitchTracker(rate: rate, window: Int(rate * 0.04))
    }

    /// Phrase currently open (not yet emitted), if any — a take must not be released while the
    /// singer is still going.
    public var openPhraseStart: Int64? { phrase.isEmpty ? nil : phraseStart }

    /// Feed consecutive voice samples (mono, session rate). Optionally the music that was playing
    /// (mono, same length): leftover music in the voice follows it, so the detector can predict
    /// the leftover level instantly when the song gets louder.
    public func feed(_ samples: UnsafeBufferPointer<Float>, reference: UnsafeBufferPointer<Float>? = nil) {
        if let reference {
            hasReference = true
            refCarry.append(contentsOf: reference.prefix(samples.count))
            let whole = refCarry.count / factor * factor
            var j = 0
            while j < whole {
                var sum: Float = 0
                for k in 0..<factor { sum += refCarry[j + k] }
                decimatedRef.append(sum / Float(factor))
                j += factor
            }
            refCarry.removeFirst(whole)
        }
        carry.append(contentsOf: samples)
        let whole = carry.count / factor * factor
        var i = 0
        while i < whole {
            var sum: Float = 0
            for k in 0..<factor { sum += carry[i + k] }
            decimated.append(sum / Float(factor))
            i += factor
        }
        carry.removeFirst(whole)

        while decimated.count >= tracker.requiredSamples {
            let frame = decimated.withUnsafeBufferPointer { tracker.analyze($0) }
            var refLevel: Float? = nil
            if hasReference, decimatedRef.count >= tracker.window {
                let w = decimatedRef[0..<tracker.window]
                refLevel = 20 * log10(sqrt(w.reduce(0) { $0 + $1 * $1 } / Float(w.count)) + 1e-9)
            }
            step(frame, at: decimatedStart, refLevel: refLevel)
            decimated.removeFirst(hop)
            if decimatedRef.count >= hop { decimatedRef.removeFirst(hop) }
            decimatedStart += Int64(hop * factor)
        }
    }

    /// Close any open phrase (session end).
    public func flush() { closePhrase() }

    private func step(_ frame: PitchFrame, at position: Int64, refLevel: Float? = nil) {
        // Floor = the higher of (a) the 20th-percentile envelope of recent frames nobody sang in,
        // and (b) leftover music predicted from the song's level + the learned leak offset.
        // Envelope follower: instant attack (a 50 ms beatbox hit counts at full level), ~100 ms release.
        smoothedLevel = floorHistory.isEmpty || frame.level > smoothedLevel ? frame.level : 0.9 * smoothedLevel + 0.1 * frame.level
        // Leftover music predicted from the song itself (when we have it).
        let predicted: Float? = refLevel.flatMap { $0 > -80 && leakLearned ? $0 + leakOffset : nil }
        let threshold = max(-90, floorCache, predicted ?? -90) + tuning.activeAboveFloor
        let wasActive = smoothedLevel > threshold
        activeRun = wasActive ? activeRun + 1 : 0
        // The floor only learns from frames nobody is singing in, so a long held line can't lift
        // it; after 8 s of unbroken "activity" it accepts that the room got louder.
        // With the song as reference, a louder section is predicted, so the escape hatch is only
        // for sessions without one — and it never teaches the leak model.
        let escapeHatch = !hasReference && activeRun > 800
        if !wasActive || escapeHatch || floorHistory.count < 50 {
            floorHistory.append(smoothedLevel)
            if floorHistory.count > tuning.floorWindowFrames { floorHistory.removeFirst() }
            if !wasActive, let refLevel, refLevel > -80 {
                // Asymmetric: falls fast to the true leak, rises slowly — so quiet singing that
                // sits just under the threshold can't drag the prediction up onto the singer.
                let offset = smoothedLevel - refLevel
                if !leakLearned { leakOffset = offset }
                else { leakOffset += offset < leakOffset ? 0.05 * (offset - leakOffset) : 0.002 * (offset - leakOffset) }
                leakLearned = true
            }
        }
        floorAge += 1
        if floorAge >= 10 || smoothedLevel < floorCache || floorHistory.count < 50 {  // settle fast at start
            let sorted = floorHistory.sorted()
            floorCache = sorted[min(sorted.count - 1, Int(Double(sorted.count) * tuning.floorPercentile))]
            floorAge = 0
        }
        let noiseFloor = max(-90, floorCache, predicted ?? -90)
        let active = smoothedLevel > noiseFloor + tuning.activeAboveFloor
        onFrame?(smoothedLevel, noiseFloor, active)
        let onset = active && (recentLevels.min().map { frame.level - $0 > tuning.onsetJump } ?? false)
        recentLevels.append(frame.level)
        if recentLevels.count > 3 { recentLevels.removeFirst() }

        if active {
            if phrase.isEmpty { phraseStart = position }
            if onset { phraseOnsets += 1 }
            phrase.append(frame)
            quietRun = 0
        } else if !phrase.isEmpty {
            phrase.append(frame)
            quietRun += 1
            if quietRun >= tuning.quietToSplit { closePhrase() }
        }
    }

    private func closePhrase() {
        defer { phrase.removeAll(); quietRun = 0; phraseOnsets = 0 }
        let frames = Array(phrase.dropLast(quietRun))
        guard !frames.isEmpty else { return }
        let seconds = Double(frames.count) / 100
        guard seconds >= tuning.minDuration else { return }

        let voiced = frames.filter(\.voiced).count
        let voicedRatio = Float(voiced) / Float(frames.count)
        let end = phraseStart + Int64(Double(frames.count) * sampleRate / 100)
        if tuning.detectBeatbox, voicedRatio <= tuning.beatboxMaxVoiced, Double(phraseOnsets) / seconds >= tuning.beatboxMinOnsetsPerSecond {
            onSegment?(SingingSegment(start: phraseStart, end: end, confidence: min(1, Float(phraseOnsets) / Float(seconds * 4)),
                                      medianHz: 0, kind: .beatbox))
            return
        }
        let held = heldFrames(frames)
        let heldRatio = voiced > 0 ? Float(held) / Float(voiced) : 0
        guard voicedRatio >= tuning.minVoicedRatio, heldRatio >= tuning.minHeldRatio else {
            if emitCandidates { onSegment?(SingingSegment(start: phraseStart, end: end, confidence: 0, medianHz: 0, kind: .other)) }
            return
        }

        let pitches = frames.filter(\.voiced).map(\.hz).sorted()
        let confidence = min(1, 0.5 * voicedRatio + 0.5 * heldRatio + 0.1)
        onSegment?(SingingSegment(start: phraseStart, end: end, confidence: confidence,
                                  medianHz: pitches[pitches.count / 2], kind: .singing))
    }

    /// Frames inside held-note runs, after smoothing pitch over one vibrato cycle.
    private func heldFrames(_ frames: [PitchFrame]) -> Int {
        let cents = frames.map { $0.voiced ? 1_200 * log2($0.hz / 55) : Float.nan }
        let w = tuning.vibratoFrames
        var smooth = [Float](repeating: .nan, count: cents.count)
        for i in cents.indices where !cents[i].isNaN {
            let lo = max(0, i - w / 2), hi = min(cents.count, i + w / 2 + 1)
            let window = cents[lo..<hi].filter { !$0.isNaN }
            smooth[i] = window.reduce(0, +) / Float(window.count)
        }

        var total = 0, runStart = 0
        func endRun(_ end: Int) { if end - runStart >= tuning.holdFrames { total += end - runStart } }
        for i in 1...smooth.count {
            let breaks = i == smooth.count || smooth[i].isNaN || smooth[runStart].isNaN
                || abs(smooth[i] - smooth[runStart]) > tuning.holdCents
            if breaks {
                if !smooth[runStart].isNaN { endRun(i) }
                runStart = i
            }
        }
        return total
    }
}
