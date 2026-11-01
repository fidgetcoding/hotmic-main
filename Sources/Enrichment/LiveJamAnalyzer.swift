import Detection
import Foundation

/// What's happening right now while you jam, for the overlay.
public struct JamReadout: Equatable, Sendable {
    public var chord: String?      // "Am"
    public var key: String?        // "C major"
    public var bpm: Int?
    public var note: String?       // "E4", the note being sung/played loudest
    public init(chord: String? = nil, key: String? = nil, bpm: Int? = nil, note: String? = nil) {
        self.chord = chord; self.key = key; self.bpm = bpm; self.note = note
    }
}

/// Streaming chord / key / tempo / note readout. `feed` is cheap (copies into a rolling buffer on
/// the caller's thread); analysis runs on its own queue twice a second and never blocks capture.
public final class LiveJamAnalyzer: @unchecked Sendable {
    public var onReadout: (@Sendable (JamReadout) -> Void)?

    private let sampleRate: Double
    private let lock = NSLock()
    private var buffer: [Float] = []          // last ≤ 35 s, trimmed to 30 s
    private var sinceUpdate = 0
    private var updates = 0
    private var busy = false
    private var missed = false                // an update came due while busy: run again right after
    private var readout = JamReadout()
    private let queue = DispatchQueue(label: "io.bluegum.hotmic.jam-readout", qos: .utility)

    public init(sampleRate: Double) { self.sampleRate = sampleRate }

    public func feed(_ mono: UnsafeBufferPointer<Float>) {
        let keep = Int(30 * sampleRate), period = Int(0.5 * sampleRate)
        lock.lock()
        buffer.append(contentsOf: mono)
        if buffer.count > keep + Int(5 * sampleRate) { buffer.removeFirst(buffer.count - keep) }
        sinceUpdate += mono.count
        var due = false
        if sinceUpdate >= period {
            if busy { missed = true } else { due = true; sinceUpdate = 0; busy = true; updates += 1 }
        }
        let tick = updates
        lock.unlock()
        guard due else { return }
        queue.async { [weak self] in self?.analyze(tick: tick) }
    }

    private func tail(_ seconds: Double) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return Array(buffer.suffix(Int(seconds * sampleRate)))
    }

    private func analyze(tick: Int) {
        defer {
            lock.lock()
            let again = missed
            missed = false
            if again { updates += 1 } else { busy = false }
            let next = updates
            lock.unlock()
            if again { queue.async { [weak self] in self?.analyze(tick: next) } }   // catch up to the newest audio
        }
        let recent = tail(1.5)
        let level = sqrt(recent.reduce(0) { $0 + $1 * $1 } / Float(max(1, recent.count)))
        guard level > 0.002 else {            // ≈ −54 dBFS: nobody's playing
            readout.chord = nil; readout.note = nil
            onReadout?(readout)
            return
        }
        let chord = ChordRecognizer().chords(recent, sampleRate: sampleRate).last?.name
        readout.chord = chord == "N" ? nil : chord
        readout.note = Self.note(in: Array(recent.suffix(Int(0.08 * sampleRate))), sampleRate: sampleRate)
        if tick % 4 == 0 {                    // every 2 s
            readout.bpm = TempoEstimator().estimate(tail(12), sampleRate: sampleRate)
                .flatMap { $0.confidence > 0.2 ? Int($0.bpm.rounded()) : nil } ?? readout.bpm
        }
        if tick % 8 == 0 {                    // every 4 s
            readout.key = KeyDetector().detect(tail(30), sampleRate: sampleRate)?.description ?? readout.key
        }
        onReadout?(readout)
    }

    static let names = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]

    static func note(in x: [Float], sampleRate: Double) -> String? {
        let factor = max(1, Int(sampleRate / 16_000))
        let y = Decimate.lowpass(x, factor: factor)
        var tracker = PitchTracker(rate: Float(sampleRate / Double(factor)))
        guard y.count >= tracker.requiredSamples else { return nil }
        let frame = y.withUnsafeBufferPointer { tracker.analyze(UnsafeBufferPointer(rebasing: $0[0..<tracker.requiredSamples])) }
        guard frame.voiced, frame.hz > 0 else { return nil }
        let midi = Int((69 + 12 * log2(Double(frame.hz) / 440)).rounded())
        return names[((midi % 12) + 12) % 12] + "\(midi / 12 - 1)"
    }
}
