import AVFoundation
import XCTest
@testable import Capture

final class LinearEchoCancellerTests: XCTestCase {
    func noise(_ n: Int, seed: UInt64) -> [Float] {
        var s = seed
        return (0..<n).map { _ in
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return (Float(s >> 40) / Float(1 << 24) - 0.5) * 0.6
        }
    }

    func convolve(_ x: [Float], _ h: [Float]) -> [Float] {
        var y = [Float](repeating: 0, count: x.count)
        for i in 0..<x.count { for (j, tap) in h.enumerated() where i >= j { y[i] += tap * x[i - j] } }
        return y
    }

    func rms(_ x: ArraySlice<Float>) -> Float { sqrt(x.reduce(0) { $0 + $1 * $1 } / Float(max(x.count, 1))) }

    /// Two speakers → one mic via different short rooms, plus a sung tone from 3 s.
    func scenario(seconds: Int, withVoice: Bool) -> (mic: [Float], ref: [Float], voice: [Float]) {
        let rate = 16_000, count = rate * seconds
        let left = noise(count, seed: 1), right = noise(count, seed: 2)
        let hl: [Float] = [0, 0, 0, 0.5, 0.2, -0.1, 0.05], hr: [Float] = [0, 0, 0, 0, 0, 0.3, 0.25, -0.12, 0.04]
        let bleedL = convolve(left, hl), bleedR = convolve(right, hr)
        var voice = [Float](repeating: 0, count: count)
        if withVoice { for i in (3 * rate)..<count { voice[i] = 0.15 * sin(Float(i) * 2 * .pi * 220 / Float(rate)) } }
        var mic = [Float](repeating: 0, count: count), ref = [Float](repeating: 0, count: count * 2)
        for i in 0..<count {
            mic[i] = bleedL[i] + bleedR[i] + voice[i]
            ref[2 * i] = left[i]; ref[2 * i + 1] = right[i]
        }
        return (mic, ref, voice)
    }

    func run(_ aec: LinearEchoCanceller, mic: [Float], ref: [Float], chunk: Int = 800) -> [Float] {
        var out = mic
        out.withUnsafeMutableBufferPointer { o in
            ref.withUnsafeBufferPointer { r in
                for start in stride(from: 0, to: mic.count - chunk + 1, by: chunk) {
                    aec.process(mic: UnsafeMutableBufferPointer(rebasing: o[start..<start + chunk]),
                                reference: UnsafeBufferPointer(rebasing: r[(2 * start)..<(2 * (start + chunk))]),
                                frames: chunk)
                }
            }
        }
        return out
    }

    func smallConfig() -> LinearEchoCanceller.Config {
        var c = LinearEchoCanceller.Config()
        c.block = 128; c.partitions = 4; c.stepSize = 0.5
        return c
    }

    func testRemovesStereoBleed() {
        let s = scenario(seconds: 3, withVoice: false)
        let aec = LinearEchoCanceller(config: smallConfig())
        let out = run(aec, mic: s.mic, ref: s.ref)
        let suppression = 20 * log10(rms(s.mic[32_000...]) / rms(out[32_000...]))
        XCTAssertGreaterThan(suppression, 25, "got \(suppression) dB")
    }

    func testKeepsTheVoice() {
        let s = scenario(seconds: 5, withVoice: true)
        let aec = LinearEchoCanceller(config: smallConfig())
        let out = run(aec, mic: s.mic, ref: s.ref)
        let lag = aec.latencyFrames
        // Residual after removing the (latency-shifted) voice should be far below the voice itself.
        var residual = [Float](), voice = [Float]()
        for i in (64_000)..<(80_000 - lag) { voice.append(s.voice[i]); residual.append(out[i + lag] - s.voice[i]) }
        let voiceToResidual = 20 * log10(rms(voice[...]) / rms(residual[...]))
        XCTAssertGreaterThan(voiceToResidual, 15, "got \(voiceToResidual) dB")
    }

    func testOutputLengthMatchesInputForOddChunks() {
        let s = scenario(seconds: 1, withVoice: false)
        let aec = LinearEchoCanceller(config: smallConfig())
        XCTAssertEqual(run(aec, mic: s.mic, ref: s.ref, chunk: 333).count, s.mic.count)
    }
}

final class LongNoteTests: XCTestCase {
    /// Audit #25: a note held for 10 s over music is still intact at the end (the freeze must not
    /// release after ~6 s and let the filter learn the voice away).
    func testTenSecondHeldNoteSurvives() {
        let t = LinearEchoCancellerTests()
        let rate = 16_000, seconds = 14
        let left = t.noise(rate * seconds, seed: 1), right = t.noise(rate * seconds, seed: 2)
        let bleedL = t.convolve(left, [0, 0, 0, 0.5, 0.2, -0.1]), bleedR = t.convolve(right, [0, 0, 0, 0, 0.3, 0.2])
        var voice = [Float](repeating: 0, count: rate * seconds)
        for i in (3 * rate)..<(13 * rate) { voice[i] = 0.15 * sin(Float(i) * 2 * .pi * 196 / Float(rate)) }
        var mic = [Float](repeating: 0, count: voice.count), ref = [Float](repeating: 0, count: voice.count * 2)
        for i in voice.indices { mic[i] = bleedL[i] + bleedR[i] + voice[i]; ref[2 * i] = left[i]; ref[2 * i + 1] = right[i] }
        var config = LinearEchoCanceller.Config()
        config.block = 128; config.partitions = 4; config.sampleRate = Double(rate)
        let aec = LinearEchoCanceller(config: config)
        let out = t.run(aec, mic: mic, ref: ref)
        let lag = aec.latencyFrames
        var v = [Float](), r = [Float]()
        for i in (11 * rate)..<(13 * rate - lag) { v.append(voice[i]); r.append(out[i + lag] - voice[i]) }
        let kept = 20 * log10(t.rms(v[...]) / t.rms(r[...]))
        // Measured 2026-09-27: 22.1 dB with the sustained-freeze hold, 16.0 dB without it.
        XCTAssertGreaterThan(kept, 19, "voice vs residual in the last 2 s of the held note: \(kept) dB")
    }
}

final class LouderRoomTests: XCTestCase {
    func suppressionAfterGainStep(db: Float, measureFrom a: Int, to b: Int) -> Float {
        let t = LinearEchoCancellerTests()
        let rate = 16_000, seconds = 30
        let left = t.noise(rate * seconds, seed: 3), right = t.noise(rate * seconds, seed: 4)
        let bl = t.convolve(left, [0, 0, 0, 0.5, 0.2, -0.1]), br = t.convolve(right, [0, 0, 0, 0, 0.3, 0.2])
        let gain = pow(10, db / 20)
        var mic = [Float](repeating: 0, count: left.count), ref = [Float](repeating: 0, count: left.count * 2)
        for i in mic.indices {
            mic[i] = (i < 5 * rate ? 1 : gain) * (bl[i] + br[i]); ref[2 * i] = left[i]; ref[2 * i + 1] = right[i]
        }
        var config = LinearEchoCanceller.Config()
        config.block = 128; config.partitions = 4; config.sampleRate = Double(rate)
        let out = t.run(LinearEchoCanceller(config: config), mic: mic, ref: ref)
        return 20 * log10(t.rms(mic[(a * rate)..<(b * rate)]) / t.rms(out[(a * rate)..<(b * rate)]))
    }

    /// Speakers turned up a few dB: re-learned within ~2 s (never mistaken for singing).
    func testSmallVolumeChangeRecoversFast() {
        XCTAssertGreaterThan(suppressionAfterGainStep(db: 3, measureFrom: 7, to: 9), 20)
    }

    /// A sudden +10 dB jump takes the slow path by design (see LinearEchoCanceller.riseFrozen) but
    /// is re-learned within ~20 s, not a minute.
    func testBigVolumeJumpRecoversWithinTwentySeconds() {
        XCTAssertGreaterThan(suppressionAfterGainStep(db: 10, measureFrom: 26, to: 29), 20)
    }
}

final class AACLowRateTests: XCTestCase {
    /// AirPods-style mics: 16 and 24 kHz, mono and stereo, with the app's bit rates.
    func testBluetoothSampleRatesStillRecord() throws {
        for rate in [16_000.0, 24_000.0, 44_100.0, 48_000.0] {
            for (channels, bitRate) in [(1, 96_000), (2, 192_000)] {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("hm-aac-\(UUID()).m4a")
                defer { try? FileManager.default.removeItem(at: url) }
                let writer = try AACFileWriter(url: url, sampleRate: rate, channels: channels, bitRate: bitRate)
                let frames = Int(rate)
                let tone = (0..<(frames * channels)).map { Float(0.2 * sin(Double($0 / channels) * 2 * .pi * 440 / rate)) }
                try tone.withUnsafeBufferPointer { try writer.append(interleaved: $0, frames: frames) }
                try writer.finish()
                let file = try AVAudioFile(forReading: url)
                XCTAssertEqual(Double(file.length) / file.fileFormat.sampleRate, 1, accuracy: 0.1, "\(rate) Hz × \(channels)")
            }
        }
    }
}
