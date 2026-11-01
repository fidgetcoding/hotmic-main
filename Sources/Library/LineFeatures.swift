import AVFoundation
import Detection
import Foundation

/// What a line sounded like, from the session recording: how much of it was pitched, and how much the pitch
/// moved. Only for lines whose times can be trusted (Whisper's collapsed lines get none).
public struct LineAudio: Codable, Equatable, Sendable {
    /// Share of voiced frames among the ones above the noise floor, 0…1.
    public var voiced: Double
    /// Spread of the pitch in semitones.
    public var pitchSpread: Double
    public init(voiced: Double, pitchSpread: Double) { self.voiced = voiced; self.pitchSpread = pitchSpread }

    /// Reads each row's stretch from the session's voice files. Files only: no audio device is touched.
    public static func measure(_ rows: [SungRow], segments: [URL], segmentSeconds: Double) -> [String: LineAudio] {
        guard let first = segments.first, let probe = try? AVAudioFile(forReading: first) else { return [:] }
        let rate = probe.processingFormat.sampleRate
        var out: [String: LineAudio] = [:]
        for row in rows where row.duration >= 0.5 {
            let part = WholeSong.read(row.at, row.at + row.duration, segments: segments, segmentSeconds: segmentSeconds, channels: 1, rate: rate)
            out[row.id] = part.first.flatMap { measure($0, rate: rate) } ?? LineAudio(voiced: 0, pitchSpread: 0)
        }
        return out
    }

    static func measure(_ samples: [Float], rate: Double) -> LineAudio? {
        let step = max(1, Int(rate / 16_000))      // close enough to 16 kHz for pitch; the tracker takes any rate
        let x = stride(from: 0, to: samples.count, by: step).map { samples[$0] }
        var tracker = PitchTracker(rate: Float(rate) / Float(step))
        let need = tracker.requiredSamples, hop = Int(0.02 * rate / Double(step))
        guard hop > 0, x.count > need else { return nil }
        var active = 0, voiced = 0, semis: [Double] = []
        x.withUnsafeBufferPointer { p in
            var a = 0
            while a + need <= p.count {
                let frame = tracker.analyze(UnsafeBufferPointer(rebasing: p[a..<(a + need)]))
                if frame.level > -50 {
                    active += 1
                    if frame.voiced, frame.hz > 0 { voiced += 1; semis.append(12 * log2(Double(frame.hz) / 440)) }
                }
                a += hop
            }
        }
        guard active > 0 else { return nil }
        let mean = semis.isEmpty ? 0 : semis.reduce(0, +) / Double(semis.count)
        let spread = semis.isEmpty ? 0 : (semis.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(semis.count)).squareRoot()
        return LineAudio(voiced: Double(voiced) / Double(active), pitchSpread: spread)
    }
}

/// Line sound measurements kept beside the takes (`line-audio.json`), so a re-run needs no audio.
public enum LineAudioCache {
    public static let fileName = "line-audio.json"
    public static func read(_ folder: URL) -> [String: LineAudio] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return [:] }
        return (try? JSONDecoder().decode([String: LineAudio].self, from: data)) ?? [:]
    }
    public static func write(_ all: [String: LineAudio], to folder: URL) {
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: folder.appendingPathComponent(fileName), options: .atomic) }
    }
}

/// A line as numbers for the learner: sparse, hashed words (the words themselves are never stored), then
/// a few measured things in fixed slots.
public enum LineFeatures {
    /// Fixed slots below `wordBase`; hashed words and word pairs above.
    enum Slot: Int { case short, length, repeats, position, speed, voiced, pitch, rap, singing, playing, rhyme, chatter }
    static let wordBase = 64, wordBuckets = 1 << 16

    public struct Context {
        let tokens: [String: [String]]
        let index: [String: Int]
        let ordered: [[String]]
        public init(_ rows: [SungRow]) {
            let all = rows.map { LabSessionExport.words($0.text) }
            ordered = all
            tokens = Dictionary(zip(rows.map(\.id), all), uniquingKeysWith: { a, _ in a })
            index = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// The model's verdict isn't a feature: it comes in as the lean every score starts from.
    public static func make(_ row: SungRow, context: Context, audio: LineAudio?) -> [Int: Double] {
        var x: [Int: Double] = [:]
        let t = context.tokens[row.id] ?? LabSessionExport.words(row.text)
        for w in Set(t) { x[wordBase + bucket(w)] = 1 }
        for (a, b) in zip(t, t.dropFirst()) { x[wordBase + bucket(a + " " + b)] = 0.7 }
        func set(_ s: Slot, _ v: Double) { if v != 0 { x[s.rawValue] = v } }
        set(.short, t.count <= 3 ? 1 : 0)
        set(.length, min(1, Double(t.count) / 16))
        let i = context.index[row.id] ?? 0, n = context.ordered.count
        set(.repeats, min(1, Double(nearRepeats(t, at: i, in: context.ordered)) / 4))
        set(.position, n > 1 ? Double(i) / Double(n - 1) : 0)
        if row.duration > 0.2 { set(.speed, min(1, Double(t.count) / row.duration / 6)) }
        if let audio { set(.voiced, audio.voiced); set(.pitch, min(1, audio.pitchSpread / 6)) }
        set(.rap, row.kind == "rap" ? 1 : 0)
        set(.singing, row.kind == "singing" ? 1 : 0)
        set(.playing, row.kind == "playing" ? 1 : 0)
        set(.rhyme, rhymes(t, at: i, in: context.ordered) ? 1 : 0)
        set(.chatter, WholeSong.isChatter(row.text) ? 1 : 0)
        return x
    }

    /// FNV-1a: the same bucket on every run and every Mac (Swift's own hash changes per launch).
    static func bucket(_ s: String) -> Int {
        var h: UInt32 = 2_166_136_261
        for b in s.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return Int(h) % wordBuckets
    }

    /// Lines close by (12 either side) with most of the same words.
    static func nearRepeats(_ t: [String], at i: Int, in all: [[String]]) -> Int {
        guard !t.isEmpty else { return 0 }
        let own = Set(t), need = 0.7 * Double(own.count)
        var n = 0
        for j in max(0, i - 12)..<min(all.count, i + 13) where j != i {
            if Double(own.intersection(all[j]).count) >= need { n += 1 }
        }
        return n
    }

    /// The last word ends like the last word of a line just before or after it (and isn't the same word).
    static func rhymes(_ t: [String], at i: Int, in all: [[String]]) -> Bool {
        guard let end = t.last, end.count >= 3 else { return false }
        for j in [i - 2, i - 1, i + 1, i + 2] where all.indices.contains(j) {
            if let other = all[j].last, other != end, other.count >= 3, other.suffix(2) == end.suffix(2) { return true }
        }
        return false
    }
}
