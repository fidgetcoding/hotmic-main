import Accelerate

/// Tempo from audio when no DAW clock exists (jam mode, imports): log-spectral-flux onset
/// envelope at 100 frames/s → autocorrelation over 60–190 BPM, weighted toward typical song
/// tempi so a strummed 120 isn't reported as 240 (or 60).
public struct TempoEstimator: Sendable {
    public struct Result: Equatable, Sendable, Codable {
        public var bpm: Double
        public var confidence: Double      // 0…1
        public init(bpm: Double, confidence: Double) { self.bpm = bpm; self.confidence = confidence }
    }

    public var minBPM = 60.0, maxBPM = 190.0
    public init() {}

    public func estimate(_ samples: [Float], sampleRate: Double) -> Result? {
        let envelope = onsetEnvelope(samples, sampleRate: sampleRate)
        guard envelope.count > 400 else { return nil }          // need ≥ 4 s
        let mean = vDSP.mean(envelope)
        let e = vDSP.add(-mean, envelope)
        let energy = vDSP.sumOfSquares(e)
        guard energy > 1e-9 else { return nil }
        let minLag = Int(6_000 / maxBPM), maxLag = Int(6_000 / minBPM)
        var scores = [Double](repeating: 0, count: maxLag + 2)
        e.withUnsafeBufferPointer { p in
            for lag in minLag...(maxLag + 1) {
                let n = e.count - lag
                scores[lag] = Double(vDSP.dot(UnsafeBufferPointer(rebasing: p[0..<n]),
                                              UnsafeBufferPointer(rebasing: p[lag..<(lag + n)]))) / Double(energy)
            }
        }
        // Prior: log-normal around 110 BPM, one octave wide.
        func prior(_ bpm: Double) -> Double { exp(-0.5 * pow(log2(bpm / 110), 2)) }
        var best = minLag, bestScore = -Double.infinity
        for lag in minLag...maxLag {
            let s = scores[lag] * prior(6_000 / Double(lag))
            if s > bestScore { bestScore = s; best = lag }
        }
        guard scores[best] > 0 else { return nil }
        // Parabolic refinement.
        var lag = Double(best)
        let a = scores[best - 1], b = scores[best], c = scores[best + 1]
        let denom = a - 2 * b + c
        if abs(denom) > 1e-12 { lag += 0.5 * (a - c) / denom }
        let bpm = 6_000 / lag
        return Result(bpm: (bpm * 10).rounded() / 10, confidence: min(1, max(0, scores[best] * 2)))
    }

    /// 100 Hz onset strength: positive log-magnitude spectral flux, 16 kHz analysis.
    func onsetEnvelope(_ x: [Float], sampleRate: Double) -> [Float] {
        let factor = max(1, Int((sampleRate / 16_000).rounded()))
        let y = Decimate.lowpass(x, factor: factor)
        let rate = sampleRate / Double(factor)
        let n = 1_024, hop = Int(rate / 100)
        guard y.count > n, let fft = vDSP.FFT(log2n: 10, radix: .radix2, ofType: DSPSplitComplex.self) else { return [] }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        var previous = [Float](repeating: 0, count: n / 2)
        var real = [Float](repeating: 0, count: n / 2), imag = real
        var out: [Float] = []
        var start = 0
        while start + n <= y.count {
            let frame = vDSP.multiply(Array(y[start..<(start + n)]), window)
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
            var flux: Float = 0
            for k in 1..<(n / 2) {
                let mag = log(1 + 100 * sqrt(real[k] * real[k] + imag[k] * imag[k]))
                flux += max(0, mag - previous[k])
                previous[k] = mag
            }
            out.append(flux)
            start += hop
        }
        return out
    }
}
