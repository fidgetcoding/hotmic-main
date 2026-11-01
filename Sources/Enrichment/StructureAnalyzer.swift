import Accelerate

/// A stretch of the song with one harmonic "identity". Labels are letters (A, B, …) — repeated
/// sections share a letter. Seconds are relative to the analyzed audio. Always a guess: DAW
/// locators (Hot Mic Link) win when available.
public struct SongSection: Equatable, Sendable, Codable {
    public var label: String
    public var start: Double
    public var end: Double
}

/// Section boundaries from music audio: half-second chroma frames → self-similarity →
/// Foote checkerboard novelty → peaks = boundaries → segments grouped by mean-chroma similarity.
public struct StructureAnalyzer {
    public var kernelFrames = 16         // 8 s each side: wider than a chord change
    public var minSectionFrames = 16     // no section shorter than 8 s
    public var sameSection: Float = 0.92 // cosine similarity to reuse a label
    public init() {}

    public func sections(_ audio: [Float], sampleRate: Double) -> [SongSection] {
        let frames = Self.chromaFrames(audio, sampleRate: sampleRate)
        guard frames.count >= 2 * minSectionFrames else {
            return frames.isEmpty ? [] : [SongSection(label: "A", start: 0, end: Double(frames.count) * 0.5)]
        }
        let novelty = self.novelty(frames)
        let boundaries = peaks(novelty)
        let edges = [0] + boundaries + [frames.count]

        var labels: [(String, [Float])] = []
        var out: [SongSection] = []
        for (a, b) in zip(edges, edges.dropFirst()) where b > a {
            let mean = (0..<12).map { c in frames[a..<b].reduce(0) { $0 + $1[c] } / Float(b - a) }
            let label = labels.first { Self.cosine($0.1, mean) >= sameSection }?.0
                ?? String(UnicodeScalar(UInt8(65 + min(labels.count, 25))))
            if !labels.contains(where: { $0.0 == label }) { labels.append((label, mean)) }
            out.append(SongSection(label: label, start: Double(a) * 0.5, end: Double(b) * 0.5))
        }
        return out
    }

    /// Near the start/end the kernel shrinks symmetrically (never below half size), so boundaries
    /// close to the edges are still found; unnormalized, so a lone chord change there can't outscore them.
    func novelty(_ frames: [[Float]]) -> [Float] {
        let n = frames.count
        var result = [Float](repeating: 0, count: n)
        for center in 0..<n {
            let h = min(kernelFrames, center, n - center)
            guard h >= kernelFrames / 2 else { continue }
            var score: Float = 0
            for i in -h..<h {
                for j in -h..<h {
                    let sign: Float = (i < 0) == (j < 0) ? 1 : -1  // checkerboard
                    score += sign * Self.cosine(frames[center + i], frames[center + j])
                }
            }
            result[center] = max(0, score)  // raw: a shrunken kernel sees less, so it scores less
        }
        return result
    }

    func peaks(_ novelty: [Float]) -> [Int] {
        let mean = vDSP.mean(novelty)
        let std = sqrt(vDSP.mean(vDSP.square(vDSP.add(-mean, novelty))))
        let threshold = mean + std
        var found: [Int] = []
        for i in 1..<(novelty.count - 1) where novelty[i] > threshold && novelty[i] >= novelty[i - 1] && novelty[i] >= novelty[i + 1] {
            if let last = found.last, i - last < minSectionFrames {
                if novelty[i] > novelty[last] { found[found.count - 1] = i }
            } else {
                found.append(i)
            }
        }
        return found
    }

    /// Normalized chroma per 0.5 s (non-overlapping 4,096-point frames at 8 kHz).
    static func chromaFrames(_ audio: [Float], sampleRate: Double) -> [[Float]] {
        let hop = Int(sampleRate * 0.5)
        var frames: [[Float]] = []
        var start = 0
        while start + hop <= audio.count {
            var c = KeyDetector.chroma(Array(audio[start..<min(audio.count, start + hop * 2)]), sampleRate: sampleRate)
            let norm = sqrt(vDSP.sumOfSquares(c))
            if norm > 0 { c = vDSP.divide(c, norm) }
            frames.append(c)
            start += hop
        }
        return frames
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        vDSP.dot(a, b) / (sqrt(vDSP.sumOfSquares(a) * vDSP.sumOfSquares(b)) + 1e-9)
    }
}
