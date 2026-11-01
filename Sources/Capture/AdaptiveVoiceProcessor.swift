/// The production voice path: watches for speaker bleed, runs the echo canceller, and on
/// headphones hands back the untouched mic. The canceller always runs so latency never jumps
/// when the route flips mid-take.
public final class AdaptiveVoiceProcessor: VoiceProcessing {
    public let latencyFrames: Int
    public var route: OutputRoute { bleed.route }
    public var referenceContainsVoice: Bool { bleed.monitoring }
    /// Diagnostics: detected speaker → mic delay and the bulk delay applied (seconds).
    public var detectedBleedDelay: Double? { bleed.bleedDelay }
    public var appliedBulkDelay: Double { Double(bulkDelay) / sampleRate }

    private var canceller: LinearEchoCanceller
    private let bleed: BleedDetector
    private var rawDelay: [Float]
    private let sampleRate: Double
    private let config: LinearEchoCanceller.Config
    /// Bulk delay applied to the reference when the speaker path is longer than the filter
    /// (Bluetooth speakers: 150–300 ms output latency).
    private var bulkDelay = 0
    private var bulkDelayed: [Float] = []   // interleaved stereo history for the bulk delay
    private var refScratch: [Float] = []

    public init(sampleRate: Double, prior: OutputRoute, canceller: LinearEchoCanceller? = nil) {
        let config = LinearEchoCanceller.Config.forSampleRate(sampleRate)
        let canceller = canceller ?? LinearEchoCanceller(config: config)
        self.sampleRate = sampleRate
        self.config = config
        self.canceller = canceller
        bleed = BleedDetector(sampleRate: sampleRate, prior: prior)
        latencyFrames = canceller.latencyFrames
        rawDelay = [Float](repeating: 0, count: canceller.latencyFrames)
    }

    public func process(mic: UnsafeMutableBufferPointer<Float>, reference: UnsafeBufferPointer<Float>, frames: Int) {
        bleed.observe(mic: UnsafeBufferPointer(rebasing: mic[0..<frames]), session: reference)
        rawDelay.append(contentsOf: mic.prefix(frames))
        adoptBulkDelayIfNeeded()
        if bulkDelay > 0 {
            bulkDelayed.append(contentsOf: reference.prefix(frames * 2))
            refScratch = Array(bulkDelayed.prefix(frames * 2))
            bulkDelayed.removeFirst(frames * 2)
            refScratch.withUnsafeBufferPointer { canceller.process(mic: mic, reference: $0, frames: frames) }
        } else {
            canceller.process(mic: mic, reference: reference, frames: frames)
        }
        if bleed.route == .headphones || bleed.monitoring {  // monitoring: cancelling would erase the singer
            for i in 0..<frames { mic[i] = rawDelay[i] }
        }
        rawDelay.removeFirst(frames)
    }

    /// When the agreed speaker delay is beyond ~250 ms (Bluetooth), delay the reference so the
    /// filter's 341 ms window covers the room again. Follows real changes of more than 30 ms;
    /// the canceller restarts cleanly on each change.
    private func adoptBulkDelayIfNeeded() {
        let wanted: Int
        if let delay = bleed.bleedDelay, delay > 0.25 { wanted = Int((delay - 0.05) * sampleRate) } else { wanted = 0 }
        guard abs(wanted - bulkDelay) > Int(0.03 * sampleRate) else { return }
        bulkDelay = wanted
        bulkDelayed = [Float](repeating: 0, count: bulkDelay * 2)
        canceller.reset()          // in place: the output stream never gets a gap
    }
}
