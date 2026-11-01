import Accelerate

public enum OutputRoute: Equatable, Sendable { case speakers, headphones, unknown }

public enum OutputTransport: Sendable { case builtIn, bluetooth, usb, thunderbolt, virtual, other }

/// First guess from device metadata. Audio interfaces (USB/Thunderbolt) can't say whether
/// the monitors or the phones jack is in use, so they start `unknown` and bleed decides.
public enum RoutePrior {
    public static func guess(transport: OutputTransport, dataSource: String?) -> OutputRoute {
        let source = dataSource?.lowercased() ?? ""
        switch transport {
        case .builtIn:
            if source.contains("headphone") { return .headphones }
            return .speakers
        case .bluetooth: return .headphones  // AirPods-class; BT speakers get corrected by bleed
        default: return .unknown
        }
    }
}

import CoreAudio

public extension RoutePrior {
    /// Reads the default output device's transport and (built-in) data source.
    static func currentOutput() -> OutputRoute {
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard let device: AudioObjectID = try? HAL.get(system, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0)),
              let raw: UInt32 = try? HAL.get(device, kAudioDevicePropertyTransportType, UInt32(0)) else { return .unknown }
        let transport: OutputTransport
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: transport = .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: transport = .bluetooth
        case kAudioDeviceTransportTypeUSB: transport = .usb
        case kAudioDeviceTransportTypeThunderbolt: transport = .thunderbolt
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: transport = .virtual
        default: transport = .other
        }
        let source: UInt32? = try? HAL.get(device, kAudioDevicePropertyDataSource, UInt32(0), scope: kAudioObjectPropertyScopeOutput)
        let headphones: UInt32 = 0x6864_706E  // 'hdpn'
        return guess(transport: transport, dataSource: source == headphones ? "Headphones" : nil)
    }
}

/// Ground truth from the audio itself, on 1 s windows at 8 kHz with 3-vote hysteresis:
/// - **Speakers:** the session shows up in the mic AFTER it was played (mic lags reference, 0–150 ms).
/// - **Monitoring:** the mic shows up in the session AFTER it was sung (reference lags mic, 2–60 ms),
///   i.e. the DAW is playing your voice back to you. Then the reference contains the voice, so it must
///   not be cancelled and must not be added to the mix a second time.
/// The direction comes from a GCC-PHAT peak, so periodic music or a sung vowel can't fake it.
/// Runs at 4 kHz so the search can reach Bluetooth latencies (400 ms).
public final class BleedDetector {
    public private(set) var route: OutputRoute
    public private(set) var monitoring = false
    /// Speaker → mic delay of the confirmed bleed, in seconds (nil until speakers are confirmed).
    public private(set) var bleedDelay: Double?

    private let decimation: Int
    private let rate = 4_000.0
    private let window = 4_000         // 1 s at 4 kHz
    private let maxLag = 1_600         // 400 ms: speaker → mic, incl. Bluetooth output latency
    private let monitorLag = 240       // 60 ms: DAW input monitoring round trip
    private let minMonitorLag = 8      // 2 ms: below this the direction is ambiguous
    private var lastPeakLag = 0
    private var voteLags: [Int] = []
    private let speakerThreshold: Float = 0.25
    private let headphoneThreshold: Float = 0.08
    private let monitorThreshold: Float = 0.3
    private let votesNeeded = 3
    private var mic: [Float] = []
    private var ref: [Float] = []
    private var votes: [OutputRoute] = []
    private var monitorVotes: [Bool] = []

    private let fftSize = 16_384
    private let forwardFFT = try! vDSP.DiscreteFourierTransform(count: 16_384, direction: .forward,
                                                               transformType: .complexComplex, ofType: Float.self)
    private let inverseFFT = try! vDSP.DiscreteFourierTransform(count: 16_384, direction: .inverse,
                                                               transformType: .complexComplex, ofType: Float.self)

    public init(sampleRate: Double, prior: OutputRoute) {
        decimation = max(1, Int(sampleRate / 4_000))
        route = prior
    }

    /// Call from the drain queue with each aligned chunk (mono mic, interleaved stereo session).
    public func observe(mic chunk: UnsafeBufferPointer<Float>, session: UnsafeBufferPointer<Float>) {
        var i = 0
        while i + decimation <= chunk.count {  // box-filter decimate
            var m: Float = 0, r: Float = 0
            for k in i..<(i + decimation) { m += chunk[k]; r += session[2 * k] + session[2 * k + 1] }
            mic.append(m); ref.append(r)
            i += decimation
        }
        if mic.count >= window + maxLag + monitorLag { evaluateWindow() }
    }

    private func evaluateWindow() {
        var micWin = Array(mic[maxLag..<(maxLag + window)])
        var refWin = Array(ref[0..<(window + maxLag + monitorLag)])
        mic.removeFirst(window)
        ref.removeFirst(window)
        micWin = vDSP.add(-vDSP.mean(micWin), micWin)  // remove DC
        refWin = vDSP.add(-vDSP.mean(refWin), refWin)

        let refEnergy = vDSP.sumOfSquares(refWin[maxLag..<(maxLag + window)])
        guard refEnergy > 1e-4 * Float(window) else { return }  // nothing playing: no evidence
        let micNorm = sqrt(vDSP.sumOfSquares(micWin)) + 1e-9

        // lag > 0: mic lags ref (speaker bleed). lag < 0: ref lags mic (input monitoring).
        // GCC-PHAT finds WHERE the two signals line up (whitening flattens the periodic side
        // peaks a held note or a sung vowel would otherwise create); plain normalized
        // correlation at that lag says how STRONGLY they match.
        let j = gccPhatPeak(mic: micWin, ref: refWin, maxIndex: maxLag + monitorLag)
        let lag = maxLag - j
        let slice = refWin[j..<(j + window)]
        let strength = abs(vDSP.dot(micWin, Array(slice))) / (micNorm * (sqrt(vDSP.sumOfSquares(slice)) + 1e-9))
        let bestPos: Float = lag >= 0 ? strength : 0
        let bestNeg: Float = lag <= -minMonitorLag ? strength : 0
        let peak = strength
        lastPeakLag = max(0, lag)

        let isMonitoring = bestNeg > monitorThreshold
        monitorVotes.append(isMonitoring)
        if monitorVotes.count > votesNeeded { monitorVotes.removeFirst() }
        if monitorVotes.count == votesNeeded, monitorVotes.allSatisfy({ $0 == monitorVotes[0] }) {
            monitoring = monitorVotes[0]
        }
        guard !isMonitoring else { return }  // the voice in the reference says nothing about speakers

        let bleedPeak = bestPos
        let vote: OutputRoute = bleedPeak > speakerThreshold ? .speakers : peak < headphoneThreshold ? .headphones : .unknown
        votes.append(vote)
        voteLags.append(lastPeakLag)
        if votes.count > votesNeeded { votes.removeFirst(); voteLags.removeFirst() }
        if votes.count == votesNeeded, let first = votes.first, first != .unknown, votes.allSatisfy({ $0 == first }) {
            route = first
            if first == .speakers {
                // Only trust a delay that three windows in a row agree on (±10 ms).
                let sorted = voteLags.sorted()
                if let lo = sorted.first, let hi = sorted.last, Double(hi - lo) / rate <= 0.01 {
                    bleedDelay = Double(sorted[sorted.count / 2]) / rate
                }
            } else {
                bleedDelay = nil
            }
        }
    }

    /// Index j (0...maxIndex) maximizing the PHAT-weighted cross-correlation Σ mic[n]·ref[n + j].
    private func gccPhatPeak(mic: [Float], ref: [Float], maxIndex: Int) -> Int {
        let size = fftSize
        var mr = [Float](repeating: 0, count: size), mi = mr, rr = mr, ri = mr
        var inR = [Float](repeating: 0, count: size), zeros = inR
        for i in 0..<mic.count { inR[i] = mic[i] }
        forwardFFT.transform(inputReal: inR, inputImaginary: zeros, outputReal: &mr, outputImaginary: &mi)
        inR = [Float](repeating: 0, count: size)
        for i in 0..<min(ref.count, size) { inR[i] = ref[i] }
        forwardFFT.transform(inputReal: inR, inputImaginary: zeros, outputReal: &rr, outputImaginary: &ri)
        // R · conj(M), partially whitened (PHAT-β, β = 0.75): flattens periodic side peaks but,
        // unlike full PHAT, doesn't let empty bins of a near-pure tone drown the real peak.
        var gr = [Float](repeating: 0, count: size), gi = gr
        var maxMag: Float = 0
        for k in 0..<size {
            let re = rr[k] * mr[k] + ri[k] * mi[k]
            let im = ri[k] * mr[k] - rr[k] * mi[k]
            gr[k] = re; gi[k] = im
            maxMag = max(maxMag, sqrt(re * re + im * im))
        }
        for k in 0..<size {
            let mag = sqrt(gr[k] * gr[k] + gi[k] * gi[k])
            if mag < 1e-4 * maxMag { gr[k] = 0; gi[k] = 0; continue }   // no signal in this bin
            let w = pow(mag, -0.75)
            gr[k] *= w; gi[k] *= w
        }
        var outR = [Float](repeating: 0, count: size), outI = outR
        inverseFFT.transform(inputReal: gr, inputImaginary: gi, outputReal: &outR, outputImaginary: &outI)
        zeros.removeAll()
        var best = 0, bestValue = -Float.greatestFiniteMagnitude
        for j in 0...maxIndex where outR[j] > bestValue { bestValue = outR[j]; best = j }
        return best
    }
}

public extension RoutePrior {
    /// The default input's name when it's a Bluetooth headset (AirPods-class), else nil. Their mics
    /// filter for speech, so hums and beatboxing barely reach Hot Mic (Nate's 2026-10-13 test: −63 dB).
    static func bluetoothInputName() -> String? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard let device: AudioObjectID = try? HAL.get(system, kAudioHardwarePropertyDefaultInputDevice, AudioObjectID(0)),
              let raw: UInt32 = try? HAL.get(device, kAudioDevicePropertyTransportType, UInt32(0)),
              raw == kAudioDeviceTransportTypeBluetooth || raw == kAudioDeviceTransportTypeBluetoothLE else { return nil }
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name)
        return status == noErr ? (name?.takeRetainedValue() as String?) ?? "Bluetooth mic" : "Bluetooth mic"
    }
}
