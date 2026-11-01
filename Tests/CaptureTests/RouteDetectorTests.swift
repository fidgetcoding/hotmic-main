import XCTest
@testable import Capture

final class RouteDetectorTests: XCTestCase {
    let rate = 48_000.0

    func noise(_ n: Int, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<n).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Float(state >> 40) / Float(1 << 24) - 0.5) * 0.6  // zero-mean
        }
    }

    func stereo(_ mono: [Float]) -> [Float] { mono.flatMap { [$0, $0] } }

    func testDevicePriors() {
        XCTAssertEqual(RoutePrior.guess(transport: .builtIn, dataSource: "Headphones"), .headphones)
        XCTAssertEqual(RoutePrior.guess(transport: .builtIn, dataSource: "MacBook Pro Speakers"), .speakers)
        XCTAssertEqual(RoutePrior.guess(transport: .bluetooth, dataSource: nil), .headphones)
        XCTAssertEqual(RoutePrior.guess(transport: .usb, dataSource: nil), .unknown, "interfaces can't tell monitors from phones")
    }

    func testDetectsSpeakerBleed() {
        let detector = BleedDetector(sampleRate: rate, prior: .unknown)
        let ref = noise(48_000 * 4, seed: 1)
        let delay = 480  // 10 ms
        let jitter = noise(ref.count, seed: 99)
        var mic = [Float](repeating: 0, count: ref.count)
        for i in 0..<ref.count {
            let bleed: Float = i >= delay ? 0.4 * ref[i - delay] : 0
            mic[i] = bleed + 0.05 * jitter[i]
        }
        feed(detector, mic: mic, ref: ref)
        XCTAssertEqual(detector.route, .speakers)
    }

    func testDetectsHeadphonesWhenMicIsUnrelated() {
        let detector = BleedDetector(sampleRate: rate, prior: .speakers)
        feed(detector, mic: noise(48_000 * 4, seed: 7), ref: noise(48_000 * 4, seed: 1))
        XCTAssertEqual(detector.route, .headphones)
    }

    func testSilentReferenceKeepsPrior() {
        let detector = BleedDetector(sampleRate: rate, prior: .headphones)
        feed(detector, mic: noise(48_000 * 3, seed: 7), ref: [Float](repeating: 0, count: 48_000 * 3))
        XCTAssertEqual(detector.route, .headphones, "no music playing = no evidence")
    }

    private func feed(_ d: BleedDetector, mic: [Float], ref: [Float]) {
        let s = stereo(ref)
        for start in stride(from: 0, to: mic.count - 2_400, by: 2_400) {  // 50 ms chunks like the drain queue
            mic.withUnsafeBufferPointer { m in
                s.withUnsafeBufferPointer { r in
                    d.observe(mic: UnsafeBufferPointer(rebasing: m[start..<start + 2_400]),
                              session: UnsafeBufferPointer(rebasing: r[(start * 2)..<(start + 2_400) * 2]))
                }
            }
        }
    }
}

final class MonitoringDetectionTests: XCTestCase {
    /// A realistic sung voice: pitch glides and ±3% vibrato, syllable envelope, breath noise.
    /// (A perfectly periodic tone has no single delay at all — any shift by one period matches.)
    func voice(_ n: Int) -> [Float] {
        var phase = 0.0
        var seed: UInt64 = 5
        return (0..<n).map { i in
            let t = Double(i) / 48_000
            let f = 200 * (1 + 0.15 * sin(2 * .pi * 0.3 * t)) * (1 + 0.03 * sin(2 * .pi * 5.5 * t))
            phase += 2 * .pi * f / 48_000
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let breath = (Double(seed >> 40) / Double(1 << 24) - 0.5) * 0.04
            let syllable = 0.6 + 0.4 * sin(2 * .pi * 3 * t)
            return Float(syllable * 0.2 * (sin(phase) + 0.5 * sin(2 * phase) + 0.3 * sin(3 * phase)) + breath)
        }
    }

    func run(_ d: BleedDetector, mic: [Float], ref: [Float]) {
        let s = ref.flatMap { [$0, $0] }
        for start in stride(from: 0, to: mic.count - 2_400, by: 2_400) {
            mic.withUnsafeBufferPointer { m in
                s.withUnsafeBufferPointer { r in
                    d.observe(mic: UnsafeBufferPointer(rebasing: m[start..<start + 2_400]),
                              session: UnsafeBufferPointer(rebasing: r[(start * 2)..<(start + 2_400) * 2]))
                }
            }
        }
    }

    func testDAWPlayingYourVoiceBackIsMonitoringNotSpeakers() {
        let v = voice(48_000 * 5)
        let delay = 480  // DAW round trip 10 ms: session = voice, later
        let ref = (0..<v.count).map { $0 >= delay ? 0.8 * v[$0 - delay] : 0 }
        let d = BleedDetector(sampleRate: 48_000, prior: .headphones)
        run(d, mic: v, ref: ref)
        XCTAssertTrue(d.monitoring)
        XCTAssertEqual(d.route, .headphones, "monitoring must not be mistaken for speaker bleed")
    }

    func testSpeakerBleedIsNotMonitoring() {
        let music = voice(48_000 * 5)
        let mic = (0..<music.count).map { $0 >= 480 ? 0.4 * music[$0 - 480] : 0 }
        let d = BleedDetector(sampleRate: 48_000, prior: .unknown)
        run(d, mic: mic, ref: music)
        XCTAssertFalse(d.monitoring)
        XCTAssertEqual(d.route, .speakers)
    }
}

final class PeriodicMusicTests: XCTestCase {
    /// Audit #9: a held bass note on built-in speakers (15 ms round trip, 50 Hz) must never be
    /// called "monitoring" — that would drop the singer from the mix.
    func testHeldBassNoteOnSpeakersIsNotMonitoring() {
        let n = 48_000 * 6
        var seed: UInt64 = 9
        let music: [Float] = (0..<n).map { i in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let t = Double(i) / 48_000
            return Float(0.3 * sin(2 * .pi * 50 * t) + 0.1 * sin(2 * .pi * 100 * t)) + (Float(seed >> 40) / Float(1 << 24) - 0.5) * 0.02
        }
        let mic = (0..<n).map { $0 >= 720 ? 0.4 * music[$0 - 720] : 0 }   // 15 ms
        let d = BleedDetector(sampleRate: 48_000, prior: .unknown)
        MonitoringDetectionTests().run(d, mic: mic, ref: music)
        XCTAssertFalse(d.monitoring)
    }
}

final class BluetoothLatencyTests: XCTestCase {
    /// Audit #8: Bluetooth speakers add ~300 ms; bleed must still be found and its delay reported.
    func testFindsBleedAtBluetoothLatency() throws {
        let music = MonitoringDetectionTests().voice(48_000 * 6)
        let mic = (0..<music.count).map { $0 >= 14_400 ? 0.4 * music[$0 - 14_400] : 0 }   // 300 ms
        let d = BleedDetector(sampleRate: 48_000, prior: .headphones)                   // BT prior = headphones
        MonitoringDetectionTests().run(d, mic: mic, ref: music)
        XCTAssertEqual(d.route, .speakers, "corrected from the Bluetooth prior")
        XCTAssertEqual(try XCTUnwrap(d.bleedDelay), 0.3, accuracy: 0.01)
    }
}
