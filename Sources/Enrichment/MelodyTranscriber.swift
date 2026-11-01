import Detection
import Foundation

public struct Note: Equatable, Sendable, Codable {
    public var pitch: Int          // MIDI note number, snapped to the key when one is given
    public var sungPitch: Double   // what was actually sung (fractional MIDI)
    public var start: Double       // seconds from the take start
    public var duration: Double
    public var velocity: Int

    public init(pitch: Int, sungPitch: Double, start: Double, duration: Double, velocity: Int) {
        self.pitch = pitch; self.sungPitch = sungPitch; self.start = start; self.duration = duration; self.velocity = velocity
    }
}

/// Voice → notes: singing (with words), humming, whistling — anything pitched. Pitch per 10 ms
/// (YIN), 5-frame median; notes split on unvoiced gaps, on leaps, or on smaller changes that
/// persist longer than half a vibrato cycle (so a wide vibrato stays one note and onsets stay
/// exact); one pitch per note (median), snapped to the nearest in-key pitch.
public struct MelodyTranscriber {
    public var minNote = 0.08          // s
    public var jumpSemitones = 0.7
    public var leapSemitones = 1.5     // bigger than any vibrato: split immediately
    public var persistFrames = 12      // 120 ms: longer than half a vibrato cycle (≥ 4.2 Hz)
    /// YIN reports a frame at the start of its 40 ms window; the sound is centred 20 ms later.
    static let frameCentre = 0.02
    public init() {}

    /// Per-10 ms pitch (fractional MIDI, NaN = unvoiced), aligned to sound time. Used by hard-snap tuning.
    public func pitchTrack(_ samples: [Float], sampleRate: Double) -> [Double] {
        let raw = pitchFrames(samples, sampleRate: sampleRate).map { $0.voiced ? 69 + 12 * log2(Double($0.hz) / 440) : Double.nan }
        let shift = Int(Self.frameCentre * 100)
        return [Double](repeating: .nan, count: shift) + medianFilter(raw, width: 5)
    }

    public func notes(from samples: [Float], sampleRate: Double, key: MusicalKey?) -> [Note] {
        let frames = pitchFrames(samples, sampleRate: sampleRate)
        var midi = frames.map { $0.voiced ? 69 + 12 * log2(Double($0.hz) / 440) : Double.nan }
        midi = medianFilter(midi, width: 5)

        var notes: [Note] = []
        var current: [Double] = [], levels: [Float] = [], startFrame = 0
        func close(through end: Int) {                     // end is exclusive (frame index)
            defer { current.removeAll(); levels.removeAll() }
            let duration = Double(end - startFrame) / 100
            guard duration >= minNote, !current.isEmpty else { return }
            let sung = current.sorted()[current.count / 2]
            let loudness = levels.reduce(0, +) / Float(levels.count)   // dBFS
            let velocity = Int(max(20, min(127, (loudness + 50) / 50 * 107 + 20)))
            notes.append(Note(pitch: snap(sung, to: key), sungPitch: sung, start: Double(startFrame) / 100 + Self.frameCentre,
                              duration: duration, velocity: velocity))
        }
        // Split rules: an unvoiced gap ends a note; a leap > `leapSemitones` splits at that frame;
        // a smaller change must hold for `persistFrames` on one side before it counts (vibrato
        // swings back within half a cycle, ~90–110 ms), and then splits where the change began.
        var pendingSide = 0, pendingStart = 0
        for (i, value) in midi.enumerated() {
            if value.isNaN {
                if !current.isEmpty { close(through: i) }
                pendingSide = 0
                continue
            }
            if current.isEmpty {
                startFrame = i
            } else {
                let center = current.sorted()[current.count / 2]
                let deviation = value - center
                if abs(deviation) > leapSemitones {
                    close(through: i); startFrame = i; pendingSide = 0
                } else if abs(deviation) > jumpSemitones {
                    let side = deviation > 0 ? 1 : -1
                    if side != pendingSide { pendingSide = side; pendingStart = i }
                    if i - pendingStart + 1 >= persistFrames {
                        // Move the persistent frames into a new note that starts where the change began.
                        let moved = i - pendingStart
                        let carriedPitch = Array(current.suffix(moved)), carriedLevels = Array(levels.suffix(moved))
                        current.removeLast(moved); levels.removeLast(moved)
                        close(through: pendingStart)
                        startFrame = pendingStart
                        current = carriedPitch; levels = carriedLevels
                        pendingSide = 0
                    }
                } else {
                    pendingSide = 0
                }
            }
            current.append(value)
            levels.append(frames[i].level)
        }
        if !current.isEmpty { close(through: midi.count) }
        return notes
    }

    func snap(_ sung: Double, to key: MusicalKey?) -> Int {
        let nearest = Int(sung.rounded())
        guard let key else { return nearest }
        let scale = key.scale
        return (nearest - 2...nearest + 2)
            .filter { scale.contains(($0 % 12 + 12) % 12) }
            .min { abs(Double($0) - sung) < abs(Double($1) - sung) } ?? nearest
    }

    private func pitchFrames(_ x: [Float], sampleRate: Double) -> [PitchFrame] {
        let factor = max(1, Int((sampleRate / 16_000).rounded()))
        var d = [Float]()
        var i = 0
        while i + factor <= x.count { d.append(x[i..<(i + factor)].reduce(0, +) / Float(factor)); i += factor }
        let rate = Float(sampleRate) / Float(factor)
        var tracker = PitchTracker(rate: rate, window: Int(rate * 0.04))
        let hop = Int(rate / 100)
        var frames: [PitchFrame] = []
        var start = 0
        while start + tracker.requiredSamples <= d.count {
            frames.append(d.withUnsafeBufferPointer { tracker.analyze(UnsafeBufferPointer(rebasing: $0[start...])) })
            start += hop
        }
        return frames
    }

    private func medianFilter(_ x: [Double], width: Int) -> [Double] {
        x.indices.map { i in
            guard !x[i].isNaN else { return .nan }
            let window = x[max(0, i - width / 2)...min(x.count - 1, i + width / 2)].filter { !$0.isNaN }.sorted()
            return window[window.count / 2]
        }
    }
}
