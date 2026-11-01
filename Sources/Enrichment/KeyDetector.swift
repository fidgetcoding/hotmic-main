import Accelerate

public struct MusicalKey: Equatable, Sendable, Codable, CustomStringConvertible {
    public enum Mode: String, Sendable, Codable { case major, minor }
    public var tonic: Int          // pitch class, C = 0
    public var mode: Mode
    public var confidence: Float   // margin over the runner-up, 0…1

    public init(tonic: Int, mode: Mode, confidence: Float) {
        self.tonic = tonic; self.mode = mode; self.confidence = confidence
    }

    static let names = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    /// "Amin", "Cmaj" — used in filenames.
    public var short: String { "\(Self.names[tonic])\(mode == .major ? "maj" : "min")" }
    public var description: String { "\(Self.names[tonic]) \(mode.rawValue)" }

    /// Pitch classes that belong to the key (natural minor plus the raised 7th singers use).
    public var scale: Set<Int> {
        let steps = mode == .major ? [0, 2, 4, 5, 7, 9, 11] : [0, 2, 3, 5, 7, 8, 10, 11]
        return Set(steps.map { ($0 + tonic) % 12 })
    }
}

/// Key from audio: log-frequency chroma (55 Hz–2 kHz) correlated against the 24 rotations of the
/// Krumhansl–Kessler key profiles. Run on the session (music) around a take, so the band decides
/// the key, not an off-key hum.
public struct KeyDetector {
    static let majorProfile: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minorProfile: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    public init() {}

    public func detect(_ samples: [Float], sampleRate: Double) -> MusicalKey? {
        // Too quiet to be music (a silent session, or only leftovers): no key beats a wrong one.
        guard !samples.isEmpty, sqrt(vDSP.sumOfSquares(samples) / Float(samples.count)) > 0.003 else { return nil }  // ≈ −50 dBFS
        let chroma = Self.chroma(samples, sampleRate: sampleRate)
        guard chroma.reduce(0, +) > 1e-6 else { return nil }
        var scores: [(MusicalKey, Float)] = []
        for tonic in 0..<12 {
            for (mode, profile) in [(MusicalKey.Mode.major, Self.majorProfile), (.minor, Self.minorProfile)] {
                let rotated = (0..<12).map { profile[($0 - tonic + 12) % 12] }
                scores.append((MusicalKey(tonic: tonic, mode: mode, confidence: 0), Self.pearson(chroma, rotated)))
            }
        }
        scores.sort { $0.1 > $1.1 }
        var best = scores[0].0
        best.confidence = max(0, min(1, (scores[0].1 - scores[1].1) * 5))
        return best
    }

    /// 12-bin chroma, energy-weighted, from 8 kHz-decimated audio with 4,096-point frames.
    static func chroma(_ x: [Float], sampleRate: Double) -> [Float] {
        let factor = max(1, Int(sampleRate / 8_000))
        let rate = sampleRate / Double(factor)
        let mono = Decimate.lowpass(x, factor: factor)

        let n = 4_096, log2n = vDSP_Length(12)
        guard mono.count >= n, let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            return [Float](repeating: 0, count: 12)
        }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        var bins = [Int](repeating: -1, count: n / 2)
        for k in 1..<(n / 2) {
            let hz = Double(k) * rate / Double(n)
            guard hz >= 55, hz <= 2_000 else { continue }
            let midi = 69 + 12 * log2(hz / 440)
            bins[k] = (Int(midi.rounded()) % 12 + 12) % 12
        }

        var chroma = [Float](repeating: 0, count: 12)
        var real = [Float](repeating: 0, count: n / 2), imag = real
        var start = 0
        while start + n <= mono.count {
            let frame = vDSP.multiply(Array(mono[start..<(start + n)]), window)
            real.withUnsafeMutableBufferPointer { r in
                imag.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: im.baseAddress!)
                    frame.withUnsafeBufferPointer {
                        $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                        }
                    }
                    fft.forward(input: split, output: &split)
                }
            }
            var frameChroma = [Float](repeating: 0, count: 12)
            for k in 1..<(n / 2) where bins[k] >= 0 {
                frameChroma[bins[k]] += sqrt(real[k] * real[k] + imag[k] * imag[k])
            }
            let total = frameChroma.reduce(0, +)
            if total > 0 { for c in 0..<12 { chroma[c] += frameChroma[c] / total } }
            start += n / 2
        }
        return chroma
    }

    static func pearson(_ a: [Float], _ b: [Float]) -> Float {
        let ma = vDSP.mean(a), mb = vDSP.mean(b)
        let da = vDSP.add(-ma, a), db = vDSP.add(-mb, b)
        return vDSP.dot(da, db) / (sqrt(vDSP.sumOfSquares(da) * vDSP.sumOfSquares(db)) + 1e-9)
    }
}
