import Accelerate

/// Makes every saved take comfortably playable: brings the performance to a target level
/// (measured on the audible part only, so silence doesn't skew it) and catches peaks with a
/// look-ahead limiter so nothing clips. Quiet 2 a.m. takes come out as loud as confident ones.
public struct Loudness: Sendable {
    public var targetRMS: Float = -18          // dBFS of the active (non-silent) audio
    public var ceiling: Float = -1             // dBFS peak ceiling
    public var maxGain: Float = 30             // dB — never boost pure room noise into a roar
    public var lookahead = 0.005               // s
    public var release = 0.08                  // s

    public init() {}

    /// Interleaved samples, any channel count. Returns the adjusted audio (same length).
    public func normalize(_ x: [Float], channels: Int, sampleRate: Double) -> [Float] {
        guard !x.isEmpty, channels > 0 else { return x }
        let active = activeRMS(x, channels: channels, sampleRate: sampleRate)
        guard active > 1e-6 else { return x }
        let gainDB = min(maxGain, targetRMS - 20 * log10(active))
        var y = vDSP.multiply(pow(10, gainDB / 20), x)
        limit(&y, channels: channels, sampleRate: sampleRate)
        return y
    }

    /// RMS over 50 ms blocks louder than 30 dB below the loudest block (the "performance" part).
    func activeRMS(_ x: [Float], channels: Int, sampleRate: Double) -> Float {
        let block = max(1, Int(0.05 * sampleRate)) * channels
        var energies: [Float] = []
        var i = 0
        while i < x.count {
            let slice = x[i..<min(x.count, i + block)]
            energies.append(vDSP.sumOfSquares(Array(slice)) / Float(slice.count))
            i += block
        }
        guard let loudest = energies.max(), loudest > 0 else { return 0 }
        let gate = loudest * 1e-3                // −30 dB
        let kept = energies.filter { $0 >= gate }
        return sqrt(kept.reduce(0, +) / Float(kept.count))
    }

    /// Look-ahead peak limiter: gain follows the upcoming peak (instant attack within the
    /// look-ahead, exponential release), applied equally to all channels.
    func limit(_ y: inout [Float], channels: Int, sampleRate: Double) {
        let frames = y.count / channels
        let ceilingLinear = pow(10, ceiling / 20)
        let ahead = max(1, Int(lookahead * sampleRate))
        let releaseCoeff = Float(exp(-1 / (release * sampleRate)))
        // Required gain per frame from its own peak.
        var need = [Float](repeating: 1, count: frames)
        for f in 0..<frames {
            var peak: Float = 0
            for c in 0..<channels { peak = max(peak, abs(y[f * channels + c])) }
            if peak > ceilingLinear { need[f] = ceilingLinear / peak }
        }
        // Minimum over the look-ahead window, then smooth release.
        var gain: Float = 1
        // Sliding minimum over [f, f + ahead) with a monotonic deque: O(n).
        var window = [Float](repeating: 1, count: frames)
        var deque: [Int] = []
        var head = 0
        var next = 0
        for f in 0..<frames {
            while next < min(frames, f + ahead) {
                while deque.count > head, need[deque[deque.count - 1]] >= need[next] { deque.removeLast() }
                deque.append(next); next += 1
            }
            while deque.count > head, deque[head] < f { head += 1 }
            window[f] = deque.count > head ? need[deque[head]] : 1
        }
        for f in 0..<frames {
            gain = window[f] < gain ? window[f] : releaseCoeff * gain + (1 - releaseCoeff) * window[f]
            gain = min(gain, window[f])
            for c in 0..<channels { y[f * channels + c] *= gain }
        }
    }
}
