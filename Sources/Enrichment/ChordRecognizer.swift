import Accelerate

/// A chord over a stretch of time (seconds from the start of the analyzed audio).
public struct ChordSpan: Equatable, Sendable, Codable {
    public var name: String            // "C", "Am", "G7", "Fmaj7", "Dm7", or "N" (no chord)
    public var start: Double
    public var end: Double
}

/// Chords from audio: quarter-second chroma frames → cosine match against major, minor, 7,
/// maj7 and m7 templates on all 12 roots → Viterbi smoothing (chords don't flicker) →
/// segments of at least half a second.
public struct ChordRecognizer: Sendable {
    public var hop = 0.25                      // s
    public var switchPenalty = 0.35            // Viterbi cost of changing chord
    public var minDuration = 0.5               // s
    /// Sevenths must beat the plain triad by this much: string harmonics (E's 3rd harmonic is B)
    /// otherwise turn every open C into Cmaj7.
    public var extensionBias: Float = 0.07
    public init() {}

    static let names = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    static let qualities: [(suffix: String, intervals: [Int], weights: [Float])] = [
        ("", [0, 4, 7], [1, 1, 1]),
        ("m", [0, 3, 7], [1, 1, 1]),
        ("7", [0, 4, 7, 10], [1, 1, 1, 0.7]),
        ("maj7", [0, 4, 7, 11], [1, 1, 1, 0.7]),
        ("m7", [0, 3, 7, 10], [1, 1, 1, 0.7]),
    ]

    struct Template { let name: String; let vector: [Float]; let extended: Bool }

    static let templates: [Template] = {
        var t: [Template] = []
        for q in qualities {
            for root in 0..<12 {
                var v = [Float](repeating: 0, count: 12)
                for (i, interval) in q.intervals.enumerated() { v[(root + interval) % 12] = q.weights[i] }
                let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
                t.append(Template(name: names[root] + q.suffix, vector: v.map { $0 / norm }, extended: q.intervals.count > 3))
            }
        }
        return t
    }()

    public func chords(_ audio: [Float], sampleRate: Double) -> [ChordSpan] {
        let frames = chromaFrames(audio, sampleRate: sampleRate)
        guard !frames.isEmpty else { return [] }
        let t = Self.templates
        let states = t.count + 1                   // + "N"
        // Emission score per frame/state (cosine similarity; N gets a fixed modest score).
        var emit = [[Float]](repeating: [Float](repeating: 0, count: states), count: frames.count)
        for (f, frame) in frames.enumerated() {
            let norm = sqrt(vDSP.sumOfSquares(frame.chroma))
            for (s, template) in t.enumerated() {
                emit[f][s] = norm > 0 ? vDSP.dot(frame.chroma, template.vector) / norm - (template.extended ? extensionBias : 0) : 0
            }
            emit[f][t.count] = frame.silent ? 1 : 0.45
        }
        // Viterbi with a flat switch penalty.
        var score = emit[0]
        var back = [[Int]](repeating: [Int](repeating: 0, count: states), count: frames.count)
        for f in 1..<frames.count {
            let bestPrev = score.indices.max { score[$0] < score[$1] }!
            var next = [Float](repeating: 0, count: states)
            for s in 0..<states {
                let stay = score[s], jump = score[bestPrev] - Float(switchPenalty)
                if stay >= jump { next[s] = stay + emit[f][s]; back[f][s] = s }
                else { next[s] = jump + emit[f][s]; back[f][s] = bestPrev }
            }
            score = next
        }
        var path = [Int](repeating: 0, count: frames.count)
        path[frames.count - 1] = score.indices.max { score[$0] < score[$1] }!
        for f in stride(from: frames.count - 1, to: 0, by: -1) { path[f - 1] = back[f][path[f]] }

        // Segments, dropping blips shorter than minDuration into their neighbour.
        var spans: [ChordSpan] = []
        for (f, s) in path.enumerated() {
            let name = s == t.count ? "N" : t[s].name
            let start = Double(f) * hop
            if let last = spans.last, last.name == name { spans[spans.count - 1].end = start + hop }
            else { spans.append(ChordSpan(name: name, start: start, end: start + hop)) }
        }
        var merged: [ChordSpan] = []
        for span in spans {
            if span.end - span.start < minDuration, var last = merged.popLast() { last.end = span.end; merged.append(last) }
            else if let last = merged.last, last.name == span.name { merged[merged.count - 1].end = span.end }
            else { merged.append(span) }
        }
        return merged
    }

    struct Frame { var chroma: [Float]; var silent: Bool }

    /// Chroma per `hop`, each over a 0.6 s window (chroma needs ≥ 4,096 samples at ~8 kHz).
    func chromaFrames(_ audio: [Float], sampleRate: Double) -> [Frame] {
        let hopSamples = Int(hop * sampleRate), window = Int(0.6 * sampleRate)
        guard audio.count >= window else { return [] }
        let rms = sqrt(vDSP.sumOfSquares(audio) / Float(audio.count))
        var frames: [Frame] = []
        var start = 0
        while start + window <= audio.count {
            let slice = Array(audio[start..<(start + window)])
            let level = sqrt(vDSP.sumOfSquares(slice) / Float(window))
            frames.append(Frame(chroma: KeyDetector.chroma(slice, sampleRate: sampleRate), silent: level < max(0.002, rms * 0.1)))
            start += hopSamples
        }
        return frames
    }
}
