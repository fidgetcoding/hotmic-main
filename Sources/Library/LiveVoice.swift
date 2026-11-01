import Foundation

/// The live recognizer's decisions about sound, as pure functions over samples, so they can be tested with no
/// recognizer and no microphone. LiveWords runs these.
public enum LiveVoice {
    /// Above this RMS (−42 dBFS) a 50 ms frame has a voice in it. Mumbling sits around −30; a quiet room around −60.
    public static let floor: Float = 0.008
    /// How long a request may hear nothing back before it can count as stuck, and how much sound that takes.
    public static let stuckAfter = 3.5, stuckFrames = 50      // 50 frames = 2.5 s
    /// How far before a line's first word its Whisper clip starts.
    public static let clipLead = 1.4

    /// 50 ms frames in `samples`: how many, and how many had a voice in them.
    public static func frames(_ samples: ArraySlice<Float>, rate: Double) -> (loud: Int, total: Int) {
        let hop = Int(rate * 0.05)
        guard hop > 0, samples.count >= hop else { return (0, 0) }
        var loud = 0, total = 0, i = samples.startIndex
        while i + hop <= samples.endIndex {
            var sum: Float = 0
            for j in i..<(i + hop) { sum += samples[j] * samples[j] }
            if sum / Float(hop) > floor * floor { loud += 1 }
            total += 1
            i += hop
        }
        return (loud, total)
    }

    /// Someone kept making sound through this stretch: a gap the recognizer gave no words for is a mumble, not a pause.
    public static func isVoiced(_ samples: ArraySlice<Float>, rate: Double) -> Bool {
        let f = frames(samples, rate: rate)
        return f.loud * 3 > f.total
    }

    /// A recognition request that hears you singing and sends nothing back is stuck, not slow
    /// (2026-10-14 tests: four sessions, 5 to 45 s, not one word until Stop).
    public static func isStuck(heardAnything: Bool, secondsSinceStart: Double, recent: ArraySlice<Float>, rate: Double) -> Bool {
        !heardAnything && secondsSinceStart > stuckAfter && frames(recent, rate: rate).loud >= stuckFrames
    }

    /// Words are placed by when they arrived, up to about a second after they were sung, so a line's clip reaches
    /// back further, but never into the line before.
    public static func clipStart(lineStart: Double, previousLineEnd: Double) -> Double {
        max(lineStart - clipLead, previousLineEnd)
    }
}
