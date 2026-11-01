import Accelerate
import Foundation

/// Maps a phone's mic frames onto the host session timeline: `hostFrame = a + r · phoneFrame`.
///
/// Room mode: the phone mic hears the beat through the speakers and the host has the same beat
/// from its digital tap, so cross-correlating the two gives the exact offset (speaker latency and
/// sound travel included — which is right: the singer sings to what they hear). Repeated every
/// second, a straight-line fit through the matches also follows clock drift between the devices.
/// Headphones mode: the phone reports which host frame it was playing, same fit, no correlation.
/// Before either lands, the ping-based clock estimate stands in.
public final class StreamAligner {
    public enum Mode: Equatable, Sendable { case room, headphones }
    public var mode: Mode { didSet { if mode != oldValue { matches.removeAll(); locked = false } } }

    public let phoneRate: Double
    public let hostRate: Double
    /// Host frames per phone frame when both clocks are perfect.
    public var nominalRatio: Double { hostRate / phoneRate }

    private var matches: [(phone: Double, host: Double)] = []
    private var clockGuesses: [(phone: Double, host: Double)] = []
    private var locked = false
    private var fit: (a: Double, r: Double)?
    public private(set) var lastMatchPhoneFrame: Double = -.infinity

    public init(phoneRate: Double, hostRate: Double, mode: Mode) {
        self.phoneRate = phoneRate
        self.hostRate = hostRate
        self.mode = mode
    }

    public enum Quality: Equatable, Sendable { case none, clock, locked }
    public var quality: Quality { locked ? .locked : (clockMapping != nil ? .clock : .none) }

    /// Best mapping available: the fit once locked, else the clock guess.
    public var mapping: (a: Double, r: Double)? { locked ? fit : clockMapping }

    public func hostFrame(forPhone p: Double) -> Double? { mapping.map { $0.a + $0.r * p } }
    public func phoneFrame(forHost h: Double) -> Double? { mapping.map { (h - $0.a) / $0.r } }

    /// Room mode: speaker → phone delay in ms, relative to the clock estimate (display only).
    public var roomDelayMs: Double? {
        guard locked, let fit, let clock = clockMapping, let p = matches.last?.phone else { return nil }
        return ((clock.a + clock.r * p) - (fit.a + fit.r * p)) / hostRate * 1000
    }

    /// From each audio packet: where the ping clock says the phone frame sits on the host timeline.
    public func addClockGuess(phoneFrame: Double, hostFrame: Double) {
        clockGuesses.append((phoneFrame, hostFrame))
        if clockGuesses.count > 40 { clockGuesses.removeFirst(clockGuesses.count - 40) }
    }

    private var clockMapping: (a: Double, r: Double)? {
        guard !clockGuesses.isEmpty else { return nil }
        let r = nominalRatio
        let offsets = clockGuesses.map { $0.host - r * $0.phone }.sorted()
        return (offsets[offsets.count / 2], r)
    }

    /// A trusted match: correlation peak (room) or the phone's own playback report (headphones).
    public func addMatch(phoneFrame: Double, hostFrame: Double) {
        // Drop matches that disagree wildly with a settled fit (a repeating loop can fool the
        // correlation by exactly one bar); a real change shows up as several in a row.
        if locked, let fit, abs(fit.a + fit.r * phoneFrame - hostFrame) > 0.02 * hostRate {
            outliers += 1
            guard outliers >= 4 else { return }
            matches.removeAll()
            locked = false
        }
        outliers = 0
        matches.append((phoneFrame, hostFrame))
        if matches.count > 24 { matches.removeFirst(matches.count - 24) }
        lastMatchPhoneFrame = phoneFrame
        refit()
    }
    private var outliers = 0

    private func refit() {
        let pts = matches
        guard pts.count >= 3 else { return }
        let r0 = nominalRatio
        // Offsets relative to the nominal rate; fit a line through them (small slope = drift).
        let xs = pts.map(\.phone), ys = pts.map { $0.host - r0 * $0.phone }
        let n = Double(pts.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0
        for i in pts.indices { sxx += (xs[i] - mx) * (xs[i] - mx); sxy += (xs[i] - mx) * (ys[i] - my) }
        // Drift can't be measured over a short span: hold the nominal rate until ~20 s of matches.
        let span = (xs.max() ?? 0) - (xs.min() ?? 0)
        var slope = sxx > 0 && span > 20 * phoneRate ? sxy / sxx : 0
        slope = max(-400e-6 * r0, min(400e-6 * r0, slope))   // real clocks are within a few hundred ppm
        let a = my - slope * mx
        let r = r0 + slope
        // Locked when the last three matches sit within 1.5 ms of the line.
        let tolerance = 0.0015 * hostRate
        let recent = pts.suffix(3)
        locked = recent.allSatisfy { abs(a + r * $0.phone - $0.host) < tolerance }
        if locked || fit == nil { fit = (a, r) }
    }
}

/// Finds where a short mic recording sits inside a longer stretch of the reference (GCC-PHAT:
/// whitened cross-correlation, sharp peaks even in a reverberant room).
public struct Correlator {
    /// Correlation runs at about this rate: plenty for millisecond placement, far cheaper.
    public var analysisRate: Double = 12_000
    public init() {}

    public struct Match: Equatable, Sendable {
        /// Frames (at the input rate) from the start of the reference to where the mic starts.
        public var offset: Double
        /// Peak-to-sidelobe ratio: above ~6 is a real match.
        public var sharpness: Float
    }

    public func locate(mic: [Float], in reference: [Float], sampleRate: Double) -> Match? {
        let factor = max(1, Int((sampleRate / analysisRate).rounded()))
        let m = Self.decimate(mic, factor), ref = Self.decimate(reference, factor)
        guard m.count >= 1024, ref.count > m.count else { return nil }
        // Both sides need something to match: silence or a stopped beat gives nothing.
        guard Self.rms(m) > 1e-4, Self.rms(ref) > 3e-4 else { return nil }
        var n = 1
        while n < ref.count + m.count { n <<= 1 }
        guard let dft = try? vDSP.DiscreteFourierTransform(count: n, direction: .forward, transformType: .complexComplex, ofType: Float.self),
              let idft = try? vDSP.DiscreteFourierTransform(count: n, direction: .inverse, transformType: .complexComplex, ofType: Float.self)
        else { return nil }
        let zeros = [Float](repeating: 0, count: n)
        func padded(_ x: [Float]) -> [Float] { x + [Float](repeating: 0, count: n - x.count) }
        let (mr, mi) = dft.transform(real: padded(m), imaginary: zeros)
        let (rr, ri) = dft.transform(real: padded(ref), imaginary: zeros)
        // conj(M) · R, whitened.
        var cr = [Float](repeating: 0, count: n), ci = [Float](repeating: 0, count: n)
        for k in 0..<n {
            let re = mr[k] * rr[k] + mi[k] * ri[k]
            let im = mr[k] * ri[k] - mi[k] * rr[k]
            let mag = max(sqrtf(re * re + im * im), 1e-12)
            cr[k] = re / mag; ci[k] = im / mag
        }
        let (c, _) = idft.transform(real: cr, imaginary: ci)
        let lags = ref.count - m.count + 1
        var best = 0
        for k in 0..<lags where c[k] > c[best] { best = k }
        // Sidelobe: strongest value outside ±3 ms of the peak.
        let guardBand = max(2, Int(0.003 * sampleRate / Double(factor)))
        var side: Float = 0, sum: Float = 0
        for k in 0..<lags where abs(k - best) > guardBand { side = max(side, c[k]); sum += abs(c[k]) }
        let mean = sum / Float(max(1, lags - 2 * guardBand))
        let sharpness = (c[best] - mean) / max(side - mean, 1e-9)
        // Sub-sample peak (parabola through three points).
        var refined = Double(best)
        if best > 0, best < lags - 1 {
            let y0 = c[best - 1], y1 = c[best], y2 = c[best + 1]
            let denom = y0 - 2 * y1 + y2
            if denom != 0 { refined += Double(0.5 * (y0 - y2) / denom) }
        }
        return Match(offset: refined * Double(factor), sharpness: sharpness)
    }

    static func decimate(_ x: [Float], _ factor: Int) -> [Float] {
        guard factor > 1 else { return x }
        let count = x.count / factor
        var out = [Float](repeating: 0, count: count)
        x.withUnsafeBufferPointer { p in
            for i in 0..<count {
                var s: Float = 0
                for j in 0..<factor { s += p[i * factor + j] }
                out[i] = s / Float(factor)
            }
        }
        return out
    }

    static func rms(_ x: [Float]) -> Float { x.isEmpty ? 0 : sqrtf(vDSP.meanSquare(x)) }
}
