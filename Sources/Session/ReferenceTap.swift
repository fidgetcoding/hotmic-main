import Foundation

/// The last ~90 s of what the DAW played (stereo), addressed by session frame. Phones' audio
/// arrives late over Wi-Fi, so each phone looks back into this to find and cancel the beat.
/// Written on the recorder's drain queue, read from each phone's queue.
public final class ReferenceTap: @unchecked Sendable {
    public let sampleRate: Double
    private let capacity: Int
    private var ring: [Float]
    private var end: Int64 = 0            // session frame just after the newest one stored
    private let lock = NSLock()

    public init(sampleRate: Double, seconds: Double = 90) {
        self.sampleRate = sampleRate
        capacity = Int(sampleRate * seconds)
        ring = [Float](repeating: 0, count: capacity * 2)
    }

    /// Newest session frame available (exclusive).
    public var newest: Int64 { lock.withLock { end } }
    /// Oldest session frame still held.
    public var oldest: Int64 { lock.withLock { max(0, end - Int64(capacity)) } }

    public func append(_ interleaved: UnsafeBufferPointer<Float>, frames: Int, at position: Int64) {
        lock.withLock {
            if position > end { writeSilence(Int(min(position - end, Int64(capacity)))); end = position }
            guard position + Int64(frames) > end else { return }          // already have it
            let skip = Int(end - position)
            for i in skip..<frames {
                let slot = Int((end % Int64(capacity))) * 2
                ring[slot] = interleaved[2 * i]
                ring[slot + 1] = interleaved[2 * i + 1]
                end += 1
            }
        }
    }

    private func writeSilence(_ frames: Int) {
        for k in 0..<frames {
            let slot = Int(((end + Int64(k)) % Int64(capacity))) * 2
            ring[slot] = 0; ring[slot + 1] = 0
        }
    }

    /// Interleaved stereo for `[from, from + count)`; silence wherever it isn't held.
    public func stereo(from: Int64, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count * 2)
        lock.withLock {
            // Never below frame 0: a phone singing right at the start asks for what came "before" the session.
            let lo = max(from, end - Int64(capacity), 0), hi = min(from + Int64(count), end)
            guard lo < hi else { return }
            for f in lo..<hi {
                let slot = Int(f % Int64(capacity)) * 2, i = Int(f - from) * 2
                out[i] = ring[slot]; out[i + 1] = ring[slot + 1]
            }
        }
        return out
    }

    /// Mono (L+R)/2 for `[from, from + count)`; silence wherever it isn't held.
    public func mono(from: Int64, count: Int) -> [Float] {
        let s = stereo(from: from, count: count)
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let left: Float = s[2 * i], right: Float = s[2 * i + 1]
            out[i] = 0.5 * (left + right)
        }
        return out
    }
}
