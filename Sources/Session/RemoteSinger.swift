import Capture
import Foundation
import Library
import SessionKit
import Timeline

/// One phone in the session: its mic stream → placed on the session timeline → beat bleed
/// cancelled against the DAW's own audio → the normal take pipeline (detection, lyrics, MIDI…).
/// Everything runs on the singer's own queue so a slow phone never touches the host's capture.
public final class RemoteSinger: @unchecked Sendable {
    public let device: String
    public let name: String
    public private(set) var headphones: Bool

    /// Session context the room hands every singer.
    public struct Host: @unchecked Sendable {
        public var tap: ReferenceTap
        /// Host clock seconds at session frame 0 (nil until capture has started).
        public var secondsAtFrameZero: () -> Double?
        /// Session frame → where the song was (DAW clock). Frames are reference frames: what the DAW played then.
        public var positionAt: (Int64) -> MusicalPosition?
        /// A configured take pipeline for this singer (judge, options, lyrics — same as the host's own),
        /// whose frame 0 is session frame `startFrame`.
        public var makePipeline: (_ singer: String, _ startFrame: Int64) throws -> TakePipeline
        public var folder: URL
        public init(tap: ReferenceTap, secondsAtFrameZero: @escaping () -> Double?, positionAt: @escaping (Int64) -> MusicalPosition?,
                    makePipeline: @escaping (_ singer: String, _ startFrame: Int64) throws -> TakePipeline, folder: URL) {
            self.tap = tap; self.secondsAtFrameZero = secondsAtFrameZero; self.positionAt = positionAt
            self.makePipeline = makePipeline; self.folder = folder
        }
    }

    /// Takes as they land (singer queue).
    public var onTake: ((TakeRecord) -> Void)?

    private let host: Host
    private let queue: DispatchQueue
    private var aligner: StreamAligner
    private let correlator = Correlator()
    private var rate: Double
    /// Phone audio not yet placed, starting at phone frame `base`.
    private var buffer: [Float] = []
    private var base: Int64 = 0
    /// Next phone frame expected from the network.
    public private(set) var received: Int64 = 0
    private var firstPacketAt: Date?
    private var nextCorrelation: Int64 = 0
    /// Next session frame to produce (nil until the stream is placed).
    private var head: Int64?
    private var streamStart: Int64 = 0
    private var stages: Stages?
    private var takes = 0
    private var level: Float = 0
    private var lastLoud = Date.distantPast
    private var lastTakeTitle: String?
    private var finished = false
    private var streams = 0

    private struct Stages {
        let processor: AdaptiveVoiceProcessor
        let mixer: SessionMixer
        let pipeline: TakePipeline
    }

    /// Time the echo canceller's reference runs ahead of the mic (keeps the echo path causal
    /// when the placement is off by a few ms).
    private var lead: Int64 { Int64(0.02 * host.tap.sampleRate) }

    public init(device: String, name: String, sampleRate: Double, headphones: Bool, host: Host) {
        self.device = device
        self.name = name
        self.headphones = headphones
        self.host = host
        rate = sampleRate
        queue = DispatchQueue(label: "io.bluegum.hotmic.singer", qos: .userInitiated)
        aligner = StreamAligner(phoneRate: sampleRate, hostRate: host.tap.sampleRate, mode: headphones ? .headphones : .room)
    }

    // MARK: - input

    public func ingest(_ packet: AudioPacket, clockOffset: Double?) {
        queue.async { [self] in
            guard !finished else { return }
            if packet.sampleRate != rate { restartStream(at: packet) }
            place(packet)
            if let offset = clockOffset, let s0 = host.secondsAtFrameZero() {
                let hostFrame = (packet.captureSeconds - offset - s0) * host.tap.sampleRate
                aligner.addClockGuess(phoneFrame: Double(packet.firstFrame), hostFrame: hostFrame)
            }
            if headphones, let heard = packet.heardFrame {
                aligner.addMatch(phoneFrame: Double(packet.firstFrame), hostFrame: Double(heard))
            }
            if !headphones { correlateIfDue() }
            produce()
        }
    }

    public func setHeadphones(_ on: Bool) {
        queue.async { [self] in
            headphones = on
            aligner.mode = on ? .headphones : .room
        }
    }

    /// Phone frames already received (a reconnecting phone resends from here).
    public var resumeFrame: UInt64 { queue.sync { UInt64(max(0, received)) } }

    /// The phone switched audio routes (e.g. AirPods at 24 kHz): start a fresh stream, keep the session.
    private func restartStream(at packet: AudioPacket) {
        flushRemaining()
        rate = packet.sampleRate
        aligner = StreamAligner(phoneRate: rate, hostRate: host.tap.sampleRate, mode: headphones ? .headphones : .room)
        buffer.removeAll()
        base = Int64(packet.firstFrame)
        received = base
        nextCorrelation = base
        head = nil
        firstPacketAt = nil
    }

    private func place(_ packet: AudioPacket) {
        var first = Int64(packet.firstFrame)
        var samples = PCM16.decode(packet.samples)
        if firstPacketAt == nil { firstPacketAt = Date(); base = first; received = first; nextCorrelation = first }
        if first < received {                              // resent overlap
            let overlap = Int(received - first)
            guard overlap < samples.count else { return }
            samples.removeFirst(overlap)
            first = received
        }
        if first > received {                              // frames lost for good: silence keeps time
            let gap = Int(min(first - received, Int64(rate * 60)))
            buffer.append(contentsOf: [Float](repeating: 0, count: gap))
            received += Int64(gap)
            if first > received { buffer.removeAll(); base = first; received = first }
        }
        buffer.append(contentsOf: samples)
        received += Int64(samples.count)
        for s in samples { level = max(level * 0.9995, abs(s)) }
    }

    // MARK: - placement

    /// Room mode, once per second of new audio: find the last 2 s of the phone inside the beat.
    private func correlateIfDue() {
        let window = Int64(2 * rate)
        guard received - nextCorrelation >= Int64(rate), received - base >= window else { return }
        nextCorrelation = received
        let phoneStart = received - window
        guard let predicted = aligner.hostFrame(forPhone: Double(phoneStart)) else { return }
        let hostRate = host.tap.sampleRate
        let locked = aligner.quality == .locked
        // Search before the clock guess (speaker latency + sound travel make the phone hear late).
        let before = locked ? 0.05 : 0.8, after = locked ? 0.05 : 0.2
        let segStart = Int64(predicted - before * hostRate)
        let hostWindow = Int(Double(window) * hostRate / rate)
        let segCount = hostWindow + Int((before + after) * hostRate)
        guard segStart >= host.tap.oldest, segStart + Int64(segCount) <= host.tap.newest else { return }
        var mic = Array(buffer[Int(phoneStart - base)..<Int(received - base)])
        if rate != hostRate { mic = Self.resample(mic, from: rate, to: hostRate) }
        let reference = host.tap.mono(from: segStart, count: segCount)
        guard let match = correlator.locate(mic: mic, in: reference, sampleRate: hostRate), match.sharpness > 6 else { return }
        aligner.addMatch(phoneFrame: Double(phoneStart), hostFrame: Double(segStart) + match.offset)
    }

    /// Places every phone frame that can be placed onto the session timeline and runs it through.
    private func produce() {
        guard let mapping = aligner.mapping else { return }
        if head == nil {
            // Room mode waits up to 8 s for the beat match; after that the clock guess will do.
            let waited = firstPacketAt.map { Date().timeIntervalSince($0) } ?? 0
            guard aligner.quality == .locked || waited > 8 || headphones && aligner.quality != .none else { return }
            head = Int64((mapping.a + mapping.r * Double(base)).rounded(.up))
            streamStart = head!
        }
        guard var head else { return }
        let latestPlaceable = Int64(mapping.a + mapping.r * Double(received - 2))
        let limit = min(latestPlaceable, host.tap.newest - lead)
        while head < limit {
            let n = Int(min(limit - head, Int64(host.tap.sampleRate / 2)))
            var mic = [Float](repeating: 0, count: n)
            let count = buffer.count
            buffer.withUnsafeBufferPointer { b in
                for i in 0..<n {
                    let p = (Double(head + Int64(i)) - mapping.a) / mapping.r - Double(base)
                    let k = Int(p.rounded(.down))
                    guard k >= 0, k + 1 < count else { continue }
                    let t = Float(p - Double(k))
                    mic[i] = b[k] + (b[k + 1] - b[k]) * t
                }
            }
            run(mic, at: head)
            head += Int64(n)
        }
        self.head = head
        trim(mapping: mapping)
    }

    /// Echo cancellation against the beat (reference leads by `lead`), then mix + takes.
    private func run(_ mic: [Float], at start: Int64) {
        guard let stages = stages ?? makeStages() else { return }
        let n = mic.count
        var voice = mic
        let reference = host.tap.stereo(from: start + lead, count: n)
        reference.withUnsafeBufferPointer { ref in
            voice.withUnsafeMutableBufferPointer { stages.processor.process(mic: $0, reference: ref, frames: n) }
        }
        // Voice comes out `latencyFrames` late: pair it with the beat from that far back.
        let beat = host.tap.stereo(from: start - Int64(stages.processor.latencyFrames), count: n)
        do { try stages.mixer.consume(mic: &voice, session: beat, frames: n) } catch {
            NSLog("Hot Mic: \(name)'s session file: \(error)")
        }
    }

    private func makeStages() -> Stages? {
        do {
            let rate = host.tap.sampleRate
            let processor = AdaptiveVoiceProcessor(sampleRate: rate, prior: headphones ? .headphones : .speakers)
            let pipeline = try host.makePipeline(name, streamStart - Int64(processor.latencyFrames))
            pipeline.singer = name
            pipeline.referenceContainsVoice = { processor.referenceContainsVoice }
            let origin = streamStart, latency = Int64(processor.latencyFrames), positionAt = host.positionAt
            pipeline.positionAt = { frame in positionAt(origin - latency + frame) }
            pipeline.onTake = { [weak self] take in self?.queue.async { self?.tookTake(take) } }
            // Unique per phone and per stream: two singers named alike, or a route change, never share files.
            streams += 1
            let tag = "\(TakeExporter.fileSafe(name))-\(TakeExporter.fileSafe(String(device.prefix(4))))" + (streams > 1 ? "-\(streams)" : "")
            let voice = try SegmentedAACWriter(folder: host.folder, baseName: "session__voice__by-\(tag)", sampleRate: rate, channels: 1, bitRate: 96_000)
            let mix = try SegmentedAACWriter(folder: host.folder, baseName: "session__mix__by-\(tag)", sampleRate: rate, channels: 2, bitRate: 192_000)
            let mixer = SessionMixer(voiceSink: voice, mixSink: mix)
            mixer.onMixed = { [weak self] voice, mix, frames, position in
                pipeline.consume(voice: voice, mix: mix, frames: frames, position: position)
                var peak: Float = 0
                for i in 0..<frames { peak = max(peak, abs(voice[i])) }
                if peak > 0.03 { self?.lastLoud = Date() }
            }
            mixer.onFinish = { try pipeline.finish() }
            let made = Stages(processor: processor, mixer: mixer, pipeline: pipeline)
            stages = made
            return made
        } catch {
            NSLog("Hot Mic: couldn't start \(name)'s takes: \(error)")
            finished = true
            return nil
        }
    }

    private func tookTake(_ take: TakeRecord) {
        takes += 1
        lastTakeTitle = take.position.map { "Bar \($0.bar)" }
        onTake?(take)
    }

    /// Drops phone audio that's been placed (keeping 3 s for the next correlation, 60 s at most).
    private func trim(mapping: (a: Double, r: Double)) {
        guard let head else {
            let excess = buffer.count - Int(rate * 60)
            if excess > 0 { buffer.removeFirst(excess); base += Int64(excess) }
            return
        }
        let placed = Int64(((Double(head) - mapping.a) / mapping.r).rounded(.down)) - 2
        let keep = min(placed, received - Int64(3 * rate))
        let drop = Int(max(0, min(keep - base, Int64(buffer.count))))
        if drop > Int(rate) { buffer.removeFirst(drop); base += Int64(drop) }
    }

    // MARK: - end

    /// Session over: place what's left, write the last take, close the files. Blocks until done.
    public func finish() {
        queue.sync {
            guard !finished else { return }
            flushRemaining()
            finished = true
        }
    }

    private func flushRemaining() {
        produce()
        guard let stages else { return }
        do { try stages.mixer.finish() } catch { NSLog("Hot Mic: finishing \(name)'s takes: \(error)") }
        self.stages = nil
        head = nil
    }

    public func waitForLyrics() async {
        let pipeline = queue.sync { stages?.pipeline }
        await pipeline?.waitForLyrics()
    }

    // MARK: - status

    public struct Snapshot: Identifiable, Equatable, Sendable {
        public var id: String { device }
        public var device: String
        public var name: String
        public var headphones: Bool
        public var sync: Status.Sync
        public var delayMs: Double?
        public var takes: Int
        public var singing: Bool
        public var level: Float
        public var lastTake: String?
        /// Exclusive phone-frame boundary received and processed on the singer queue.
        public var receivedFrames: Int64
    }

    public var snapshot: Snapshot {
        queue.sync {
            let sync: Status.Sync
            if headphones { sync = .headphones } else {
                switch aligner.quality {
                case .locked: sync = .locked
                case .clock: sync = head == nil ? .searching : .clockOnly
                case .none: sync = .searching
                }
            }
            let singing = Date().timeIntervalSince(lastLoud) < 1.5
            let shown = level
            level *= 0.5
            return Snapshot(device: device, name: name, headphones: headphones, sync: sync, delayMs: aligner.roomDelayMs,
                            takes: takes, singing: singing, level: shown, lastTake: lastTakeTitle, receivedFrames: received)
        }
    }

    static func resample(_ x: [Float], from: Double, to: Double) -> [Float] {
        let ratio = from / to
        let count = Int(Double(x.count) / ratio)
        return (0..<count).map { i in
            let p = Double(i) * ratio, k = Int(p)
            guard k + 1 < x.count else { return x[min(k, x.count - 1)] }
            return x[k] + (x[k + 1] - x[k]) * Float(p - Double(k))
        }
    }
}
