import Accelerate

public struct DrumHit: Equatable, Sendable {
    public enum Kind: String, Sendable, Codable { case kick, snare, hat }
    public var kind: Kind
    public var time: Double      // seconds from the take start
    public var velocity: Int

    /// General MIDI percussion note.
    public var note: Int {
        switch kind { case .kick: return 36; case .snare: return 38; case .hat: return 42 }
    }
}

/// Beatbox → drum hits. Onsets from 10 ms energy jumps; each hit classified from the spectrum of
/// its first 40 ms: energy under 200 Hz = kick ("b", "boom"), centroid above 7 kHz = hat ("ts", "t"),
/// in between = snare ("psh", "k"). Thresholds are synthetic-tuned — retune on real fixtures.
public struct DrumTranscriber {
    public var onsetJump: Float = 12          // dB over the recent minimum
    public var refractory = 0.06              // s between hits
    public init() {}

    public func hits(from samples: [Float], sampleRate: Double) -> [DrumHit] {
        let hop = Int(sampleRate / 100)
        guard samples.count > hop * 4 else { return [] }
        let levels = stride(from: 0, to: samples.count - hop, by: hop).map { start -> Float in
            let frame = samples[start..<(start + hop)]
            return 10 * log10(frame.reduce(0) { $0 + $1 * $1 } / Float(hop) + 1e-10)
        }

        var hits: [DrumHit] = []
        var lastHit = -Int.max / 2
        for i in 0..<levels.count {
            let recentMin = i == 0 ? -100 : levels[max(0, i - 3)..<i].min()!  // audio starting on a hit still counts
            guard levels[i] > -45, levels[i] - recentMin > onsetJump,
                  Double(i - lastHit) / 100 >= refractory else { continue }
            lastHit = i
            let start = i * hop
            let window = Array(samples[start..<min(samples.count, start + Int(0.04 * sampleRate))])
            let peak = window.map(abs).max() ?? 0
            let velocity = Int(max(20, min(127, (20 * log10(peak + 1e-6) + 40) / 40 * 107 + 20)))
            hits.append(DrumHit(kind: classify(window, sampleRate: sampleRate), time: Double(start) / sampleRate,
                                velocity: velocity))
        }
        return hits
    }

    func classify(_ x: [Float], sampleRate: Double) -> DrumHit.Kind {
        let n = 2_048
        var frame = [Float](repeating: 0, count: n)
        for i in 0..<min(n, x.count) { frame[i] = x[i] }
        frame = vDSP.multiply(frame, vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                                                 count: n, isHalfWindow: false))
        guard let fft = vDSP.FFT(log2n: 11, radix: .radix2, ofType: DSPSplitComplex.self) else { return .snare }
        var real = [Float](repeating: 0, count: n / 2), imag = real
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
        var low: Float = 0, total: Float = 0, weighted: Double = 0
        for k in 1..<(n / 2) {
            let hz = Double(k) * sampleRate / Double(n)
            let power = real[k] * real[k] + imag[k] * imag[k]
            total += power
            weighted += hz * Double(power)
            if hz < 200 { low += power }
        }
        guard total > 0 else { return .snare }
        let centroid = weighted / Double(total)
        if low / total > 0.4 || centroid < 400 { return .kick }
        if centroid > 7_000 { return .hat }
        return .snare
    }
}
