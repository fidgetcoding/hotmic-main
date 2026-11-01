import AVFoundation
import os
import SessionKit

/// Headphones mode: plays the host's beat and remembers which host frame reached the singer's ears
/// when. The Mac lines each take up with that frame, so it never has to hear the beat in the room.
final class BeatPlayer: @unchecked Sendable {
    /// One render call: from `seconds` on (phone clock, output latency included) the singer heard
    /// `frame`, advancing at the beat rate while `moving`, frozen while the buffer was dry.
    private struct Anchor { var seconds: Double; var frame: Int64; var moving: Bool }

    /// Enough of a cushion to ride out Wi-Fi hiccups without making the beat feel late.
    static let prefillSeconds = 0.25
    /// Past this the phone has fallen behind the Mac: skip ahead instead of drifting further.
    static let maxBufferedSeconds = 0.75
    private static let anchorCapacity = 256

    private let lock = OSAllocatedUnfairLock()
    private(set) var sampleRate: Double
    private var ring: UnsafeMutablePointer<Float>
    private var capacity: Int
    /// Host frame of the next sample to play.
    private var readFrame: Int64 = 0
    /// Host frame just past the newest buffered sample.
    private var writeFrame: Int64 = 0
    private var hasData = false
    private var primed = false
    private var enabled = false
    private var anchors: UnsafeMutablePointer<Anchor>
    private var anchorHead = 0
    private var anchorCount = 0
    private var outputLatency: Double = 0

    /// A beat arrived at a different rate: the source node has to be rebuilt (main queue).
    var onRateChange: ((Double) -> Void)?

    init(sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
        capacity = Int(sampleRate * 4)
        ring = .allocate(capacity: capacity)
        ring.initialize(repeating: 0, count: capacity)
        anchors = .allocate(capacity: Self.anchorCapacity)
        anchors.initialize(repeating: Anchor(seconds: 0, frame: 0, moving: false), count: Self.anchorCapacity)
    }

    deinit {
        ring.deallocate()
        anchors.deallocate()
    }

    /// Off: packets are dropped and nothing is heard. Either way the buffer starts over.
    func setEnabled(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        enabled = on
        resetLocked()
    }

    func setOutputLatency(_ seconds: Double) {
        lock.lock(); outputLatency = seconds; lock.unlock()
    }

    /// New rate: fresh buffer. Only called from the main queue while the node is being rebuilt.
    func reconfigure(sampleRate rate: Double) {
        lock.lock(); defer { lock.unlock() }
        guard rate != sampleRate else { return }
        ring.deallocate()
        sampleRate = rate
        capacity = Int(rate * 4)
        ring = .allocate(capacity: capacity)
        ring.initialize(repeating: 0, count: capacity)
        resetLocked()
    }

    // MARK: - network side (client queue)

    func push(_ packet: BeatPacket) {
        lock.lock()
        guard enabled, !packet.samples.isEmpty else { lock.unlock(); return }
        if packet.sampleRate != sampleRate {
            lock.unlock()
            let rate = packet.sampleRate
            DispatchQueue.main.async { self.onRateChange?(rate) }
            return
        }
        defer { lock.unlock() }
        var skip = 0
        let gap = packet.hostFrame - writeFrame
        if !hasData || gap > Int64(sampleRate / 2) || gap < -Int64(sampleRate) {
            // First packet, or the host jumped (transport moved, long dropout): start over there.
            resetLocked()
            readFrame = packet.hostFrame
            writeFrame = packet.hostFrame
            hasData = true
        } else if gap > 0 {
            // A dropped packet: keep the timeline honest with silence rather than squeezing it out.
            for _ in 0..<Int(gap) { writeSample(0) }
        } else if gap < 0 {
            skip = Int(-gap)                                  // overlap: already have those frames
            guard skip < packet.samples.count else { return }
        }
        for i in skip..<packet.samples.count { writeSample(Float(packet.samples[i]) / 32_767) }
        let buffered = writeFrame - readFrame
        if primed, buffered > Int64(sampleRate * Self.maxBufferedSeconds) {
            readFrame = writeFrame - Int64(sampleRate * Self.prefillSeconds)
        }
    }

    private func writeSample(_ value: Float) {
        if writeFrame - readFrame >= Int64(capacity) { readFrame += 1 }   // full: drop the oldest
        ring[index(writeFrame)] = value
        writeFrame += 1
    }

    private func index(_ frame: Int64) -> Int {
        let i = Int(frame % Int64(capacity))
        return i < 0 ? i + capacity : i
    }

    // MARK: - render side (audio thread)

    /// Fills `out` with the next frames. Underruns play silence and freeze the heard frame.
    func render(into out: UnsafeMutablePointer<Float>, count: Int, timestamp: AudioTimeStamp) {
        let renderSeconds = timestamp.mFlags.contains(.hostTimeValid)
            ? HostClock.seconds(fromHostTime: timestamp.mHostTime) : HostClock.now()
        lock.lock()
        let buffered = writeFrame - readFrame
        if hasData, !primed, buffered >= Int64(sampleRate * Self.prefillSeconds) { primed = true }
        let startFrame = readFrame
        var played = 0
        if primed {
            played = Int(min(Int64(count), buffered))
            for i in 0..<played {
                out[i] = ring[index(readFrame)]
                readFrame += 1
            }
            if played < count { primed = false }             // dry: wait for a fresh cushion
        }
        if hasData { addAnchor(Anchor(seconds: renderSeconds + outputLatency, frame: startFrame, moving: played > 0)) }
        lock.unlock()
        if played < count { (out + played).update(repeating: 0, count: count - played) }
    }

    private func addAnchor(_ anchor: Anchor) {
        anchors[(anchorHead + anchorCount) % Self.anchorCapacity] = anchor
        if anchorCount < Self.anchorCapacity { anchorCount += 1 } else { anchorHead = (anchorHead + 1) % Self.anchorCapacity }
    }

    // MARK: - mapping (mic tap thread)

    /// The host frame the singer was hearing at `seconds` (phone clock). nil before any beat played.
    func heardFrame(at seconds: Double) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        guard anchorCount > 0 else { return nil }
        // Newest render that had started by then; older than every anchor → the oldest one.
        var chosen = anchors[anchorHead]
        for k in stride(from: anchorCount - 1, through: 0, by: -1) {
            let a = anchors[(anchorHead + k) % Self.anchorCapacity]
            if a.seconds <= seconds { chosen = a; break }
        }
        guard chosen.moving else { return chosen.frame }
        return chosen.frame + Int64(((seconds - chosen.seconds) * sampleRate).rounded())
    }

    private func resetLocked() {
        hasData = false
        primed = false
        readFrame = 0
        writeFrame = 0
        anchorHead = 0
        anchorCount = 0
    }
}
