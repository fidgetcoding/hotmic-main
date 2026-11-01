import AVFoundation
import XCTest
@testable import Detection

/// Synthetic voices at 48 kHz. Real-voice fixtures live in fixtures/ (spec).
enum Voice {
    static let rate = 48_000.0

    static func tone(hz: (Double) -> Double, seconds: Double, amp: Float = 0.2) -> [Float] {
        let n = Int(seconds * rate)
        var phase = 0.0
        return (0..<n).map { i in
            phase += 2 * .pi * hz(Double(i) / rate) / rate
            let edge = min(1, min(Double(i), Double(n - i)) / (0.02 * rate))
            return amp * Float(edge * (sin(phase) + 0.5 * sin(2 * phase) + 0.25 * sin(3 * phase)) / 1.75)
        }
    }

    static func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * rate)) }

    static func noise(_ seconds: Double, amp: Float, seed: UInt64 = 3) -> [Float] {
        var s = seed
        return (0..<Int(seconds * rate)).map { _ in
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return amp * (Float(s >> 40) / Float(1 << 24) - 0.5) * 2
        }
    }

    static func withRoom(_ x: [Float]) -> [Float] {
        let hiss = noise(Double(x.count) / rate, amp: 0.0003, seed: 11)
        return zip(x, hiss).map(+)
    }

    /// Sung melody with 5.5 Hz ±40-cent vibrato.
    static func singing() -> [Float] {
        let notes = [220.0, 246.9, 261.6, 293.7, 261.6, 246.9, 220.0, 196.0]
        return notes.flatMap { f in
            tone(hz: { t in f * pow(2, 40 * sin(2 * .pi * 5.5 * t) / 1_200) }, seconds: 0.45) + silence(0.03)
        }
    }

    static func humming() -> [Float] {
        [110.0, 130.8, 146.8, 130.8].flatMap { f in tone(hz: { _ in f }, seconds: 0.6, amp: 0.12) }
    }

    /// Speech-like: short voiced syllables whose pitch glides, fricative noise, short gaps.
    static func talking() -> [Float] {
        var out: [Float] = []
        for k in 0..<10 {
            let from = 190.0 - Double(k % 3) * 15, to = from * 0.7
            out += tone(hz: { t in from + (to - from) * t / 0.18 }, seconds: 0.18, amp: 0.2)
            out += noise(0.07, amp: 0.05, seed: UInt64(k + 1))
            out += silence(0.06)
        }
        return out
    }
}

final class SingingDetectorTests: XCTestCase {
    func detect(_ signal: [Float]) -> [SingingSegment] {
        let detector = SingingDetector(sampleRate: Voice.rate)
        var found: [SingingSegment] = []
        detector.onSegment = { found.append($0) }
        let audio = Voice.withRoom(Voice.silence(0.5) + signal + Voice.silence(1.0))
        audio.withUnsafeBufferPointer { all in
            for start in stride(from: 0, to: all.count, by: 2_400) {
                detector.feed(UnsafeBufferPointer(rebasing: all[start..<min(all.count, start + 2_400)]))
            }
        }
        detector.flush()
        return found
    }

    func testSungMelodyWithVibratoIsSinging() {
        let segments = detect(Voice.singing())
        XCTAssertEqual(segments.count, 1)
        if let s = segments.first {
            XCTAssertEqual(Double(s.start) / Voice.rate, 0.5, accuracy: 0.1, "starts where the singing starts")
            XCTAssertEqual(Double(s.medianHz), 240, accuracy: 30)
        }
    }

    func testHummingIsSinging() {
        XCTAssertEqual(detect(Voice.humming()).count, 1)
    }

    func testTalkingIsNotSinging() {
        XCTAssertEqual(detect(Voice.talking()), [])
    }

    func testNoiseAndSilenceAreNotSinging() {
        XCTAssertEqual(detect(Voice.noise(2, amp: 0.1)), [])
        XCTAssertEqual(detect(Voice.silence(2)), [])
    }

    func testTooShortIsIgnored() {
        XCTAssertEqual(detect(Voice.tone(hz: { _ in 220 }, seconds: 0.4)), [])
    }
}

final class TakeSlicerTests: XCTestCase {
    func seg(_ a: Double, _ b: Double) -> SingingSegment {
        SingingSegment(start: Int64(a * 48_000), end: Int64(b * 48_000), confidence: 0.8, medianHz: 220)
    }

    func testMergesBreathsAndPads() {
        let takes = TakeSlicer(sampleRate: 48_000).takes(from: [seg(10, 14), seg(15, 18), seg(30, 32)])
        XCTAssertEqual(takes.map { Double($0.start) / 48_000 }, [8.5, 28.5])
        XCTAssertEqual(takes.map { Double($0.end) / 48_000 }, [19.5, 33.5])
    }

    func testClampsAtSessionStart() {
        XCTAssertEqual(TakeSlicer(sampleRate: 48_000).takes(from: [seg(0.5, 3)]).first?.start, 0)
    }
}

final class BeatboxDetectionTests: XCTestCase {
    func testBeatboxPhraseIsABeatboxTakeNotSinging() {
        var seed: UInt64 = 21
        func noise() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return (Float(seed >> 40) / Float(1 << 24) - 0.5) * 2 }
        var audio = [Float](repeating: 0, count: Int(4 * Voice.rate))
        for hit in 0..<14 {                         // 14 hits over 3.5 s = 4/s
            let start = Int((0.25 + Double(hit) * 0.25) * Voice.rate)
            for j in 0..<Int(0.05 * Voice.rate) where start + j < audio.count {
                audio[start + j] += noise() * 0.3 * Float(exp(-Double(j) / Voice.rate / 0.015))
            }
        }
        let detector = SingingDetector(sampleRate: Voice.rate)
        var found: [SingingSegment] = []
        detector.onSegment = { found.append($0) }
        let all = Voice.withRoom(Voice.silence(0.5) + audio + Voice.silence(1))
        all.withUnsafeBufferPointer { detector.feed($0) }
        detector.flush()
        XCTAssertEqual(found.map(\.kind), [.beatbox])
    }
}

final class AppleVoiceJudgeTests: XCTestCase {
    func speech(_ text: String) throws -> ([Float], Double) {
        let aiff = FileManager.default.temporaryDirectory.appendingPathComponent("hm-judge-\(UUID()).aiff")
        defer { try? FileManager.default.removeItem(at: aiff) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", aiff.path, text]
        try say.run(); say.waitUntilExit()
        let file = try AVAudioFile(forReading: aiff)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buf)
        return (Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))), file.processingFormat.sampleRate)
    }

    func testTalkingIsDropped() throws {
        let (samples, rate) = try speech("so anyway I was thinking we should move the session to Thursday afternoon")
        let judge = AppleVoiceJudge()
        let s = try XCTUnwrap(judge.scores(samples, sampleRate: rate))
        XCTAssertGreaterThan(s.speech, max(s.singing, s.rapping), "\(s)")
        XCTAssertNil(judge.judge(samples, sampleRate: rate, detected: .other))
    }

    func testBeatboxPassesThroughAndPitchOnlyDropsOther() {
        XCTAssertEqual(AppleVoiceJudge().judge([0.1, 0.2], sampleRate: 48_000, detected: .beatbox), .beatbox)
        XCTAssertNil(PitchOnlyJudge().judge([], sampleRate: 48_000, detected: .other))
    }
}

final class AppleVoiceJudgeSingingTests: XCTestCase {
    func testHeldNotesSurviveTheClassifier() {
        let sung = Voice.singing() + Voice.singing()
        XCTAssertEqual(AppleVoiceJudge().judge(sung, sampleRate: Voice.rate, detected: .singing), .singing)
    }
}

final class ResidualMusicTests: XCTestCase {
    /// Leftover music after echo cancellation never goes quiet; phrases must still split around it.
    func testPhrasesSplitOverContinuousLeftoverMusic() {
        let n = Int(20 * Voice.rate)
        var audio = Voice.noise(20, amp: 0.02, seed: 8)                 // ≈ −40 dBFS "leftover music"
        for (start, part) in [(3.0, Voice.singing()), (11.0, Voice.humming())] {
            let s = Int(start * Voice.rate)
            for i in part.indices where s + i < n { audio[s + i] += part[i] }
        }
        let detector = SingingDetector(sampleRate: Voice.rate)
        var found: [SingingSegment] = []
        detector.onSegment = { found.append($0) }
        audio.withUnsafeBufferPointer { detector.feed($0) }
        detector.flush()
        XCTAssertEqual(found.map(\.kind), [.singing, .singing])
        XCTAssertEqual(found.map { (Double($0.start) / Voice.rate).rounded() }, [3, 11])
    }
}

final class AuditDetectionTests: XCTestCase {
    func run(_ voice: [Float], reference: [Float]? = nil) -> [SingingSegment] {
        let d = SingingDetector(sampleRate: Voice.rate)
        var out: [SingingSegment] = []
        d.onSegment = { out.append($0) }
        voice.withUnsafeBufferPointer { v in
            if let reference { reference.withUnsafeBufferPointer { d.feed(v, reference: $0) } } else { d.feed(v) }
        }
        d.flush()
        return out
    }

    /// Audit #7: 10 s of unbroken legato singing stays one phrase (floor can't climb onto the singer).
    func testLongHeldLineIsOnePhrase() {
        var line: [Float] = []
        for m in [57.0, 59, 60, 62, 64, 62, 60, 59, 57, 55] {
            let f = 440 * pow(2, (m - 69) / 12)
            line += (0..<Int(Voice.rate)).map { i in Float(0.2 * sin(2 * .pi * f * Double(i) / Voice.rate)) }
        }
        let audio = Voice.withRoom(Voice.silence(1) + line + Voice.silence(1))
        let found = run(audio)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(Double(found.first.map { $0.end - $0.start } ?? 0) / Voice.rate, 10, accuracy: 0.5)
    }

    /// The song jumps from quiet to loud; leftover music follows it. With the song as reference the
    /// louder leftover is not mistaken for singing, so the next idea is still its own phrase.
    func testLouderSongSectionDoesNotGlueIdeasTogether() {
        let n = Int(20 * Voice.rate)
        var song = Voice.noise(20, amp: 0.05, seed: 4)
        for i in Int(8 * Voice.rate)..<n { song[i] *= 8 }                     // +18 dB at 8 s
        var voice = song.map { $0 * 0.02 }                                     // leftover music ≈ −34 dB below song
        for (start, part) in [(4.0, Voice.singing()), (13.0, Voice.humming())] {
            let s = Int(start * Voice.rate)
            for i in part.indices where s + i < n { voice[s + i] += part[i] }
        }
        let found = run(voice, reference: song)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found.map { (Double($0.start) / Voice.rate).rounded() }, [4, 13])
    }
}

final class OpenPhraseAssemblerTests: XCTestCase {
    /// Audit #6: a phrase that started within the merge gap keeps the previous take open.
    func testTakeWaitsForAPhraseStillBeingSung() {
        let rate = 48_000.0
        let assembler = LiveTakeAssembler(slicer: TakeSlicer(sampleRate: rate))
        assembler.add(SingingSegment(start: Int64(5 * rate), end: Int64(10 * rate), confidence: 1, medianHz: 220))
        XCTAssertTrue(assembler.advance(to: Int64(14 * rate), openPhraseStart: Int64(11 * rate)).isEmpty)
        assembler.add(SingingSegment(start: Int64(11 * rate), end: Int64(15 * rate), confidence: 1, medianHz: 220))
        let takes = assembler.advance(to: Int64(19 * rate))
        XCTAssertEqual(takes.count, 1, "one idea sung in breaths = one take")
        XCTAssertEqual(Double(takes[0].end) / rate, 16.5, accuracy: 0.01)
    }
}

final class LeakLockTests: XCTestCase {
    /// Verification finding: soft singing just under the threshold for a long time must not teach
    /// the leak model that the singer is "leftover music".
    func testSoftLongSingingDoesNotLockThePredictionOntoTheSinger() {
        let n = Int(40 * Voice.rate)
        let song = Voice.noise(40, amp: 0.1, seed: 12)
        var voice = song.map { $0 * 0.01 }                                     // leak ≈ −40 dB
        // 20 s of quiet humming only ~6 dB over the leak (below the 10 dB threshold), then a clear phrase.
        let soft = Voice.humming() + Voice.humming() + Voice.humming() + Voice.humming() + Voice.humming() + Voice.humming() + Voice.humming() + Voice.humming()
        for i in soft.indices where Int(2 * Voice.rate) + i < n { voice[Int(2 * Voice.rate) + i] += soft[i] * 0.02 }
        let loud = Voice.singing()
        for i in loud.indices where Int(32 * Voice.rate) + i < n { voice[Int(32 * Voice.rate) + i] += loud[i] }
        let d = SingingDetector(sampleRate: Voice.rate)
        var found: [SingingSegment] = []
        d.onSegment = { found.append($0) }
        voice.withUnsafeBufferPointer { v in song.withUnsafeBufferPointer { d.feed(v, reference: $0) } }
        d.flush()
        XCTAssertTrue(found.contains { abs(Double($0.start) / Voice.rate - 32) < 0.3 }, "the clear phrase at 32 s is still caught")
    }
}

final class WhisperJudgeTests: XCTestCase {
    /// A quiet whispered line is kept as a whisper take, not dropped as talking.
    func testClassifierKeepsAWhisperedLine() throws {
        let aiff = FileManager.default.temporaryDirectory.appendingPathComponent("hm-wj-\(UUID()).aiff")
        defer { try? FileManager.default.removeItem(at: aiff) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Whisper", "-o", aiff.path, "I keep your letters in a coat by the door, burning slow"]
        try say.run(); say.waitUntilExit()
        let file = try AVAudioFile(forReading: aiff)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))).map { $0 * 0.05 }
        let scores = try XCTUnwrap(AppleVoiceJudge().scores(samples, sampleRate: file.processingFormat.sampleRate))
        print("whisper scores:", scores)
        XCTAssertEqual(AppleVoiceJudge().judge(samples, sampleRate: file.processingFormat.sampleRate, detected: .other), .whisper)
    }
}
