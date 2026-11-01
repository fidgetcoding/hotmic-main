import Accelerate

/// Linear-only echo canceller: stereo-reference partitioned-block frequency-domain NLMS
/// (overlap-save). Subtracts what the speakers put into the mic and never gates the singer.
/// Spike 0 found call-style suppressors (WebRTC AEC3) damage a voice sung over constant music.
///
/// Output lags input by `latencyFrames` (one block); the mixer delays the session to match.
/// Signals are real, so only bins 0...block are computed; the rest are conjugate mirrors.
public final class LinearEchoCanceller: VoiceProcessing {
    public struct Config: Sendable {
        public var block = 512
        public var partitions = 32        // 32 × 512 = 341 ms of room at 48 kHz
        public var stepSize: Float = 0.4
        public var sampleRate: Double = 48_000
        public init() {}

        /// ~340 ms of room at any rate (32 × 512 at 48 kHz, 64 × 512 at 96 kHz, …).
        public static func forSampleRate(_ rate: Double) -> Config {
            var c = Config()
            c.sampleRate = rate
            c.partitions = max(16, Int((0.341 * rate / Double(c.block)).rounded()))
            return c
        }
    }

    public let latencyFrames: Int
    private let doubleTalkRatio: Float = 3  // ≈ 5 dB above the learned speaker→mic level (swept 2–6 on tests)
    private let n: Int, m: Int, p: Int, bins: Int
    private let mu: Float
    private let forward: vDSP.DiscreteFourierTransform<Float>
    private let inverse: vDSP.DiscreteFourierTransform<Float>

    // Flat storage. Spectra index: ((channel * p) + partition) * m + bin.
    private let xr, xi, wr, wi: UnsafeMutableBufferPointer<Float>
    private let previous: UnsafeMutableBufferPointer<Float>   // 2 × n
    private let power: UnsafeMutableBufferPointer<Float>      // 2 × m, smoothed |X|²
    private let micPower, echoPath, adapt: UnsafeMutableBufferPointer<Float>
    private var tr, ti, ur, ui: UnsafeMutableBufferPointer<Float>  // var: passed inout to vDSP
    private let zeros, error: UnsafeMutableBufferPointer<Float>
    private var head = 0
    private var blockIndex = 0
    private var meanRefPower: Float = 1e-6
    private let riseFollow: Float      // ×1.2 per second
    /// ×1.07 per second once a freeze is sustained. Trade-off measured 2026-09-27 on real music:
    /// a 10 s held note stays protected (path estimate grows ≤ 2×, freeze needs 3×), and speakers
    /// turned up by more than ~5 dB mid-note are re-learned in ~18 s. Smaller volume changes never
    /// freeze at all. Coherence-based detection was tried and rejected: speaker distortion looks
    /// "coherent" and cost 7–14 dB of cancellation on real music.
    private let riseFrozen: Float
    private let sustainedBlocks: Float
    private let frozenRun: UnsafeMutableBufferPointer<Float>

    // Streaming staging (arbitrary chunk sizes in, fixed blocks internally).
    private var pendingMic: [Float] = []
    private var pendingRef: [Float] = []
    private var ready: [Float] = []

    public init(config: Config = Config()) {
        n = config.block; m = 2 * config.block; p = config.partitions; mu = config.stepSize; bins = n + 1
        latencyFrames = n
        let blocksPerSecond = Float(config.sampleRate) / Float(n)
        riseFollow = pow(1.2, 1 / blocksPerSecond)
        riseFrozen = pow(1.07, 1 / blocksPerSecond)
        sustainedBlocks = 0.5 * blocksPerSecond
        forward = try! vDSP.DiscreteFourierTransform(count: m, direction: .forward,
                                                     transformType: .complexComplex, ofType: Float.self)
        inverse = try! vDSP.DiscreteFourierTransform(count: m, direction: .inverse,
                                                     transformType: .complexComplex, ofType: Float.self)
        func buffer(_ count: Int, _ value: Float = 0) -> UnsafeMutableBufferPointer<Float> {
            let b = UnsafeMutableBufferPointer<Float>.allocate(capacity: count)
            b.initialize(repeating: value)
            return b
        }
        xr = buffer(2 * p * m); xi = buffer(2 * p * m); wr = buffer(2 * p * m); wi = buffer(2 * p * m)
        previous = buffer(2 * n); power = buffer(2 * m, 1e-3)
        micPower = buffer(m); echoPath = buffer(m, .greatestFiniteMagnitude); adapt = buffer(m)
        frozenRun = buffer(m)
        tr = buffer(m); ti = buffer(m); ur = buffer(m); ui = buffer(m); zeros = buffer(m); error = buffer(n)
        ready = [Float](repeating: 0, count: n)  // primes the one-block latency
    }

    deinit {
        for b in [xr, xi, wr, wi, previous, power, micPower, echoPath, adapt, frozenRun, tr, ti, ur, ui, zeros, error] {
            b.deallocate()
        }
    }

    public func process(mic: UnsafeMutableBufferPointer<Float>, reference: UnsafeBufferPointer<Float>, frames: Int) {
        pendingMic.append(contentsOf: mic.prefix(frames))
        pendingRef.append(contentsOf: reference.prefix(frames * 2))
        var consumed = 0
        while pendingMic.count - consumed >= n {
            runBlock(micOffset: consumed)
            ready.append(contentsOf: error)
            consumed += n
        }
        if consumed > 0 {
            pendingMic.removeFirst(consumed)
            pendingRef.removeFirst(2 * consumed)
        }
        for i in 0..<frames { mic[i] = ready[i] }
        ready.removeFirst(frames)
    }

    /// Forget the room (e.g. after a bulk-delay change) without breaking the output stream.
    public func reset() {
        for b in [xr, xi, wr, wi, previous, micPower, frozenRun] { b.update(repeating: 0) }
        power.update(repeating: 1e-3)
        echoPath.update(repeating: .greatestFiniteMagnitude)
        meanRefPower = 1e-6
        blockIndex = 0
    }

    private func mirror(_ re: UnsafeMutableBufferPointer<Float>, _ im: UnsafeMutableBufferPointer<Float>) {
        for k in 1..<n { re[m - k] = re[k]; im[m - k] = -im[k] }
    }

    private func runBlock(micOffset o: Int) {
        head = (head + p - 1) % p  // newest partition slot

        // 1. Spectrum of [previous block, current block] per reference channel.
        for c in 0..<2 {
            for i in 0..<n {
                let sample = pendingRef[2 * (o + i) + c]
                tr[i] = previous[c * n + i]
                tr[n + i] = sample
                previous[c * n + i] = sample
            }
            forward.transform(inputReal: tr, inputImaginary: zeros, outputReal: &ur, outputImaginary: &ui)
            let base = (c * p + head) * m
            for k in 0..<bins {
                xr[base + k] = ur[k]; xi[base + k] = ui[k]
                power[c * m + k] = 0.9 * power[c * m + k] + 0.1 * (ur[k] * ur[k] + ui[k] * ui[k])
            }
        }

        // 2. Echo estimate: Σ_c Σ_q W[c][q] · X[c][head + q], then time domain.
        for k in 0..<m { tr[k] = 0; ti[k] = 0 }
        for c in 0..<2 {
            for q in 0..<p {
                let xb = (c * p + (head + q) % p) * m, wb = (c * p + q) * m
                for k in 0..<bins {
                    let a = wr[wb + k], b = wi[wb + k], x = xr[xb + k], y = xi[xb + k]
                    tr[k] += a * x - b * y
                    ti[k] += a * y + b * x
                }
            }
        }
        mirror(tr, ti)
        inverse.transform(inputReal: tr, inputImaginary: ti, outputReal: &ur, outputImaginary: &ui)
        let scale = 1 / Float(m)
        for i in 0..<n { error[i] = pendingMic[o + i] - ur[n + i] * scale }

        // 3. Per-bin double-talk: where the mic is much louder than the speakers alone explain,
        //    someone is singing in that band — freeze adaptation there so the voice isn't learned away.
        for i in 0..<n { tr[i] = 0; tr[n + i] = pendingMic[o + i] }
        forward.transform(inputReal: tr, inputImaginary: zeros, outputReal: &ur, outputImaginary: &ui)
        var total: Float = 0
        for k in 0..<bins { total += power[k] + power[m + k] }
        meanRefPower = 0.999 * meanRefPower + 0.001 * (total / Float(bins))
        for k in 0..<bins {
            // Fast attack, slow release: a sudden near-end burst (beatbox hit, consonant) freezes
            // adaptation in its first block instead of ~100 ms later.
            let instant = ur[k] * ur[k] + ui[k] * ui[k]
            micPower[k] = instant > micPower[k] ? instant : 0.9 * micPower[k] + 0.1 * instant
            let refPower = power[k] + power[m + k] + 1e-9
            let ratio = micPower[k] / refPower
            let frozen = ratio > doubleTalkRatio * echoPath[k]
            frozenRun[k] = frozen ? frozenRun[k] + 1 : 0
            if ratio < echoPath[k] {
                echoPath[k] = 0.7 * min(echoPath[k], ratio * 4) + 0.3 * ratio
            } else {
                // Brief freezes (a drum transient) release at the normal rate; a freeze that has
                // lasted half a second is someone singing, and then the path barely moves, so a
                // long held note can't release the freeze and get learned away.
                echoPath[k] *= frozenRun[k] > sustainedBlocks ? riseFrozen : riseFollow
            }
            let quiet = refPower < 1e-6 * meanRefPower
            adapt[k] = ratio > doubleTalkRatio * echoPath[k] || quiet ? 0 : mu / (Float(p) * refPower + 1e-3 * meanRefPower + 1e-10)
        }

        // 4. Error spectrum of [zeros, error], NLMS update normalized by total reference power.
        for i in 0..<n { tr[i] = 0; tr[n + i] = error[i] }
        forward.transform(inputReal: tr, inputImaginary: zeros, outputReal: &ur, outputImaginary: &ui)
        for c in 0..<2 {
            for q in 0..<p {
                let xb = (c * p + (head + q) % p) * m, wb = (c * p + q) * m
                for k in 0..<bins {
                    let g = adapt[k], x = xr[xb + k], y = xi[xb + k]
                    wr[wb + k] += g * (x * ur[k] + y * ui[k])  // conj(X)·E
                    wi[wb + k] += g * (x * ui[k] - y * ur[k])
                }
            }
        }

        // 5. Keep one partition per channel a true linear filter (round-robin gradient constraint).
        let q = blockIndex % p
        blockIndex += 1
        for c in 0..<2 { constrain(base: (c * p + q) * m) }
    }

    private func constrain(base wb: Int) {
        for k in 0..<bins { tr[k] = wr[wb + k]; ti[k] = wi[wb + k] }
        mirror(tr, ti)
        inverse.transform(inputReal: tr, inputImaginary: ti, outputReal: &ur, outputImaginary: &ui)
        let scale = 1 / Float(m)
        for i in 0..<m { ur[i] = i < n ? ur[i] * scale : 0 }
        forward.transform(inputReal: ur, inputImaginary: zeros, outputReal: &tr, outputImaginary: &ti)
        for k in 0..<bins { wr[wb + k] = tr[k]; wi[wb + k] = ti[k] }
    }
}

public extension VoiceProcessing {
    var latencyFrames: Int { 0 }
    var referenceContainsVoice: Bool { false }
}
