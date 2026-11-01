import Accelerate

/// One 10 ms analysis frame.
public struct PitchFrame: Equatable, Sendable {
    public var level: Float        // RMS, dBFS
    public var voiced: Bool
    public var hz: Float           // 0 when unvoiced
}

/// YIN pitch tracker at ~16 kHz (Cheveigné & Kawahara 2002): cumulative-mean-normalized
/// difference function, absolute threshold, parabolic refinement. 60–1,000 Hz covers humming
/// through soprano.
public struct PitchTracker {
    public let rate: Float
    public let window: Int
    private let minLag: Int, maxLag: Int
    private let threshold: Float = 0.15
    private var diff: [Float]

    public init(rate: Float, window: Int = 640, minHz: Float = 60, maxHz: Float = 1_000) {
        self.rate = rate
        self.window = window
        minLag = max(2, Int(rate / maxHz))
        maxLag = min(window / 2, Int(rate / minHz))
        diff = [Float](repeating: 0, count: maxLag + 2)
    }

    /// Needs `window + maxLag` samples.
    public var requiredSamples: Int { window + maxLag }

    public mutating func analyze(_ x: UnsafeBufferPointer<Float>) -> PitchFrame {
        precondition(x.count >= requiredSamples)
        let head = UnsafeBufferPointer(rebasing: x[0..<window])
        let rms = sqrt(vDSP.sumOfSquares(head) / Float(window))
        let level = 20 * log10(rms + 1e-9)

        // d(τ) = Σ (x[j] − x[j+τ])² = e0 + eτ − 2·r(τ)
        let e0 = vDSP.sumOfSquares(head)
        var running: Float = 0
        diff[0] = 1
        for tau in 1...maxLag {
            let shifted = UnsafeBufferPointer(rebasing: x[tau..<(tau + window)])
            let d = e0 + vDSP.sumOfSquares(shifted) - 2 * vDSP.dot(head, shifted)
            running += d
            diff[tau] = running > 0 ? d * Float(tau) / running : 1
        }

        var best = -1
        var tau = minLag
        while tau <= maxLag {
            if diff[tau] < threshold {
                while tau + 1 <= maxLag, diff[tau + 1] < diff[tau] { tau += 1 }
                best = tau
                break
            }
            tau += 1
        }
        guard best > 0 else { return PitchFrame(level: level, voiced: false, hz: 0) }

        var refined = Float(best)
        if best > minLag, best < maxLag {
            let a = diff[best - 1], b = diff[best], c = diff[best + 1]
            let denom = a - 2 * b + c
            if abs(denom) > 1e-9 { refined += 0.5 * (a - c) / denom }
        }
        return PitchFrame(level: level, voiced: true, hz: rate / refined)
    }
}
