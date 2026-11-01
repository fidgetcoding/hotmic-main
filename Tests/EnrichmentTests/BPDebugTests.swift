import XCTest
@testable import Enrichment

/// Opt-in (HM_BP_DUMP=<dir>): dumps Basic Pitch activations + our extracted notes so the Python
/// reference (basic_pitch.note_creation) can be run on the same numbers.
final class BPDebugTests: XCTestCase {
    func testDumpForReferenceComparison() throws {
        guard let dir = ProcessInfo.processInfo.environment["HM_BP_DUMP"] else { throw XCTSkip("set HM_BP_DUMP") }
        let rate = 48_000.0, n = Int(2 * rate)
        func bar(_ chord: [Int], _ sung: Int) -> [Float] {
            var out = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = Double(i) / rate
                var guitar = 0.0
                for m in chord {
                    let f = Synth.hz(Double(m))
                    guitar += exp(-t / 0.8) * (sin(2 * .pi * f * t) + 0.3 * sin(4 * .pi * f * t))
                }
                let fs = Synth.hz(Double(sung))
                let voice = min(1, t / 0.02) * (sin(2 * .pi * fs * t) + 0.3 * sin(4 * .pi * fs * t))
                out[i] = Float(0.25 * guitar / Double(chord.count) + 0.2 * voice)
            }
            return out
        }
        let audio = bar([48, 52, 55, 60], 64) + bar([43, 47, 50, 55], 74)
        let (frames, onsets) = try PolyphonicTranscriber().activations(PolyphonicTranscriber.resample(audio, from: rate))
        var settings = PolyphonicTranscriber.Settings()
        settings.lowestMIDI = 21
        let events = PolyphonicTranscriber.extract(frames: frames, onsets: onsets, settings: settings)
        let json: [String: Any] = ["frames": frames, "onsets": onsets,
                                   "events": events.map { [$0.start, $0.end, $0.pitch] }]
        try JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: dir).appendingPathComponent("bp.json"))
    }
}
