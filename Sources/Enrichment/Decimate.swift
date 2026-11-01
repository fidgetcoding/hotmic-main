import Accelerate

/// Band-limited downsampling: windowed-sinc low-pass, then keep every `factor`th sample.
/// (Plain averaging lets hi-hats and cymbals fold down into the pitch range.)
enum Decimate {
    static func lowpass(_ x: [Float], factor: Int) -> [Float] {
        guard factor > 1, x.count > factor else { return x }
        let taps = 16 * factor + 1, mid = Double(taps - 1) / 2
        let cutoff = 0.45 / Double(factor)                       // of the input rate: 0.9 × new Nyquist
        var h = (0..<taps).map { i -> Float in
            let t = Double(i) - mid
            let sinc = t == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * t) / (.pi * t)
            let hann = 0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(taps - 1))
            return Float(sinc * hann)
        }
        let gain = h.reduce(0, +)
        h = h.map { $0 / gain }
        let padded = [Float](repeating: 0, count: taps / 2) + x + [Float](repeating: 0, count: taps)
        let n = x.count / factor
        return vDSP.downsample(padded, decimationFactor: factor, filter: h).prefix(n).map { $0 }
    }
}
