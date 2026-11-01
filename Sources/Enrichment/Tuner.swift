import CStretch
import Foundation

/// The tuned take (signalsmith-stretch; duration never changes).
/// - natural (default): one constant shift per note, so vibrato, slides and phrasing survive.
/// - hard: every 10 ms is pulled onto the note's pitch (the "T-Pain" snap).
/// `strength` 1 = fully in tune, 0.5 = halfway.
public struct Tuner {
    public enum Mode: String, CaseIterable, Sendable, Codable { case natural, hard }

    public var mode: Mode = .natural
    public var strength: Double = 1.0
    public var glide = 0.03          // s ramp between corrections (natural)
    public init(mode: Mode = .natural) { self.mode = mode }

    public func tune(_ samples: [Float], sampleRate: Double, notes: [Note], pitchTrack: [Double]? = nil) -> [Float] {
        guard !samples.isEmpty, !notes.isEmpty, let engine = hm_stretch_create(Float(sampleRate)) else { return samples }
        defer { hm_stretch_destroy(engine) }
        let latency = Int(hm_stretch_latency(engine))
        // The engine shifts the frame `inputLatency` behind the newest input, so look the target up there.
        let lookBack = Double(hm_stretch_input_latency(engine)) / sampleRate
        let block = mode == .hard ? 128 : 256
        let track = mode == .hard ? (pitchTrack ?? MelodyTranscriber().pitchTrack(samples, sampleRate: sampleRate)) : []

        func semitones(at t: Double) -> Double {
            guard let note = notes.first(where: { t >= $0.start && t < $0.start + $0.duration }) else { return 0 }
            if mode == .hard {
                let i = Int(t * 100)
                if i >= 0, i < track.count, !track[i].isNaN { return (Double(note.pitch) - track[i]) * strength }
            }
            return (Double(note.pitch) - note.sungPitch) * strength
        }

        let input = samples + [Float](repeating: 0, count: latency + block)
        var output = [Float](repeating: 0, count: input.count)
        var current = 0.0
        let step = mode == .hard ? 1.0 : Double(block) / sampleRate / max(glide, 1e-3)
        var start = 0
        input.withUnsafeBufferPointer { inp in
            output.withUnsafeMutableBufferPointer { out in
                while start < input.count {
                    let n = min(block, input.count - start)
                    let target = semitones(at: Double(start) / sampleRate - lookBack)
                    current += max(-step * 12, min(step * 12, target - current))
                    hm_stretch_set_transpose(engine, Float(pow(2, current / 12)))
                    hm_stretch_process(engine, inp.baseAddress! + start, out.baseAddress! + start, Int32(n))
                    start += n
                }
            }
        }
        return Array(output[latency..<(latency + samples.count)])
    }
}
