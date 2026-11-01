import AVFoundation
import XCTest
@testable import Capture
@testable import Detection
@testable import Library

/// Final-phase test: a whole scripted session through the production path (AdaptiveVoiceProcessor
/// → SessionMixer with real AAC files → TakePipeline with Apple's classifier), on real music
/// played through a simulated laptop-speaker room. Opt-in, release build:
///   HM_E2E=1 HM_E2E_MUSIC=<path to an instrumental> swift test -c release --filter SessionSimulationTests
final class SessionSimulationTests: XCTestCase {
    static let rate = 48_000.0
    static let music = ProcessInfo.processInfo.environment["HM_E2E_MUSIC"] ?? ""

    struct Event { let start: Double; let expected: SingingSegment.Kind?; let audio: [Float] }

    func testScriptedSessionProducesTheRightTakes() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HM_E2E"] == "1", "set HM_E2E=1 (release build recommended)")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.music), "set HM_E2E_MUSIC to a reference instrumental")
        let seconds = 45.0, n = Int(seconds * Self.rate)

        // Session audio (what the DAW plays): real instrumental, stereo.
        let session = try loadStereo(Self.music, skip: 30, count: n)
        // Mic = the music through a laptop-speaker room + the singer + room noise.
        var mic = room(session.enumerated().filter { $0.offset % 2 == 0 }.map { $0.element + session[$0.offset + 1] })
        let events = [
            Event(start: 5, expected: .singing, audio: sung(notes: [57, 60, 64, 62, 60, 57, 55, 57], each: 0.45, vibrato: true)),
            Event(start: 13, expected: nil, audio: try speech("okay so let's move the chorus after the second verse and try that again")),
            Event(start: 21, expected: nil, audio: beatbox(hits: 14)),   // beatbox is off in V1
            Event(start: 29, expected: .singing, audio: sung(notes: [48, 50, 52, 50], each: 0.7, vibrato: false)),
        ]
        for e in events { let s = Int(e.start * Self.rate); for i in e.audio.indices where s + i < n { mic[s + i] += e.audio[i] } }

        // Production path.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hm-e2e-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let processor = AdaptiveVoiceProcessor(sampleRate: Self.rate, prior: .speakers)
        let pipeline = try TakePipeline(folder: folder, sampleRate: Self.rate, sessionStart: Date(), daw: "Ableton Live",
                                        route: { "\(processor.route)" })
        pipeline.judge = AppleVoiceJudge()
        pipeline.beatboxEnabled = false
        let mixer = SessionMixer(
            voiceSink: try SegmentedAACWriter(folder: folder, baseName: "session__voice", sampleRate: Self.rate, channels: 1, bitRate: 96_000, segmentSeconds: 20),
            mixSink: try SegmentedAACWriter(folder: folder, baseName: "session__mix", sampleRate: Self.rate, channels: 2, bitRate: 192_000, segmentSeconds: 20),
            processor: processor)
        var cleanedMusicOnly: [Float] = []
        var cleanedLate: [Float] = []
        var cleaned: [Float] = []
        mixer.onMixed = { voice, mix, frames, position in
            pipeline.consume(voice: voice, mix: mix, frames: frames, position: position)
            cleaned += voice.prefix(frames)
            if position >= Int64(2 * Self.rate), position < Int64(4.5 * Self.rate) { cleanedMusicOnly += voice.prefix(frames) }
            if position >= Int64(38 * Self.rate), position < Int64(44 * Self.rate) { cleanedLate += voice.prefix(frames) }
        }
        mixer.onFinish = { try pipeline.finish() }

        let chunk = 2_400
        let started = Date()
        var start = 0
        while start + chunk <= n {
            var m = Array(mic[start..<(start + chunk)])
            try mixer.consume(mic: &m, session: Array(session[(2 * start)..<(2 * (start + chunk))]), frames: chunk)
            start += chunk
        }
        try mixer.finish()
        let realtime = Date().timeIntervalSince(started) / seconds

        // Report.
        let takes = pipeline.takes
        let rawMusicOnly = Array(mic[Int(2 * Self.rate)..<Int(4.5 * Self.rate)])
        let suppression = 20 * log10(rms(rawMusicOnly) / max(rms(cleanedMusicOnly), 1e-9))
        let rawLate = Array(mic[Int(38 * Self.rate)..<Int(44 * Self.rate)])
        print("HM_E2E late suppression=\(String(format: "%.1f", 20 * log10(rms(rawLate) / max(rms(cleanedLate), 1e-9)))) dB")
        // Level trace (dBFS per 0.5 s) of the cleaned voice, to see residual music vs ideas.
        let trace = stride(from: 0, to: cleaned.count - 24_000, by: 24_000).map { Int(20 * log10(rms(Array(cleaned[$0..<($0 + 24_000)])) + 1e-9)) }
        print("HM_E2E levels \(trace)")
        let probe = SingingDetector(sampleRate: Self.rate)
        probe.emitCandidates = true
        probe.onSegment = { seg in
            let v = Array(cleaned[Int(seg.start)..<min(cleaned.count, Int(seg.end))])
            let verdict = AppleVoiceJudge().judge(v, sampleRate: Self.rate, detected: seg.kind)
            let sc = AppleVoiceJudge().scores(v, sampleRate: Self.rate)
            print("HM_E2E seg \(seg.kind) \(String(format: "%.2f-%.2f", Double(seg.start) / Self.rate, Double(seg.end) / Self.rate)) judge=\(String(describing: verdict)) \(String(describing: sc))")
        }
        var frame = 0
        var line = ""
        probe.onFrame = { level, floor, active in
            if frame >= 2_050, frame < 3_000, frame % 10 == 0 { line += " \(frame / 10):\(Int(level))/\(Int(floor))\(active ? "*" : "")" }
            frame += 1
        }
        cleaned.withUnsafeBufferPointer { probe.feed($0) }
        print("HM_E2E trace", line)
        for (name, a, b) in [("sing", 5.0, 8.8), ("talk", 13.0, 17.0), ("beatbox", 21.0, 24.5), ("hum", 29.0, 31.8), ("music", 38.0, 44.0)] {
            let lo = Int(a * Self.rate), hi = Int(b * Self.rate), d = processor.latencyFrames
            let ev = events.first { abs($0.start - a) < 0.01 }
            let voiceOnly = ev.map { rms(Array($0.audio.prefix(hi - lo))) } ?? 0
            print("HM_E2E level \(name): raw mic \(Int(20 * log10(rms(Array(mic[lo..<hi])) + 1e-9))) dB, cleaned \(Int(20 * log10(rms(Array(cleaned[(lo + d)..<(hi + d)])) + 1e-9))) dB, event alone \(Int(20 * log10(voiceOnly + 1e-9))) dB")
        }
        probe.flush()
        print("HM_E2E bleedDelay=\(String(describing: processor.detectedBleedDelay)) bulk=\(processor.appliedBulkDelay)")
        print("HM_E2E route=\(processor.route) realtime=\(String(format: "%.3f", realtime)) suppression=\(String(format: "%.1f", suppression)) dB")
        for t in takes { print("HM_E2E take \(t.kind ?? "?") start=\(String(format: "%.2f", t.sessionStartSeconds)) dur=\(String(format: "%.1f", t.durationSeconds)) key=\(t.key?.short ?? "-") files=\(t.files.keys.sorted())") }

        // Expectations.
        let expected = events.filter { $0.expected != nil }
        XCTAssertEqual(takes.count, expected.count, "one take per musical idea, talking dropped")
        for (take, event) in zip(takes, expected) {
            XCTAssertEqual(take.kind, event.expected?.rawValue)
            XCTAssertEqual(take.sessionStartSeconds + 1.5, event.start, accuracy: 0.6, "take starts at the idea (after 1.5 s padding)")
        }
        XCTAssertEqual(processor.route, .speakers, "bleed detector confirms speakers")
        XCTAssertLessThan(realtime, 0.25, "whole pipeline well under real time")
        let late = 20 * log10(rms(rawLate) / max(rms(cleanedLate), 1e-9))
        XCTAssertGreaterThan(late, 15, "music removed from the voice on speakers once the canceller has settled")
        for base in ["session__voice", "session__mix"] {
            let parts = (1...3).map { folder.appendingPathComponent(String(format: "%@_%03d.m4a", base, $0)) }
            let total = try parts.reduce(Int64(0)) { $0 + (try AVAudioFile(forReading: $1).length) }
            XCTAssertGreaterThan(total, Int64(seconds * Self.rate * 0.95), "3 × 20 s crash-safe segments cover the session")
        }
    }

    // MARK: - signal helpers

    func loadStereo(_ path: String, skip: Double, count: Int) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2)!
        let converter = AVAudioConverter(from: file.processingFormat, to: format)!
        file.framePosition = AVAudioFramePosition(skip * file.processingFormat.sampleRate)
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(Double(count) * file.processingFormat.sampleRate / Self.rate) + 4_096)!
        try file.read(into: input)
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count + 4_096))!
        var fed = false
        _ = converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return input
        }
        var stereo = [Float](repeating: 0, count: count * 2)
        let peak = (0..<Int(out.frameLength)).reduce(Float(0)) { max($0, abs(out.floatChannelData![0][$1])) }
        for i in 0..<min(count, Int(out.frameLength)) {
            stereo[2 * i] = out.floatChannelData![0][i] / max(peak, 1e-6) * 0.4
            stereo[2 * i + 1] = out.floatChannelData![1][i] / max(peak, 1e-6) * 0.4
        }
        return stereo
    }

    /// Laptop speaker → room → mic: 8 ms delay, short reverb, speaker band, mild distortion, hiss.
    func room(_ x: [Float]) -> [Float] {
        let delay = Int(0.008 * Self.rate)
        var ir = [Float](repeating: 0, count: Int(0.12 * Self.rate))
        var s: UInt64 = 3
        for i in ir.indices {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            ir[i] = (Float(s >> 40) / Float(1 << 24) - 0.5) * 0.12 * Float(exp(-Double(i) / Self.rate / 0.03))
        }
        ir[0] = 1
        var y = [Float](repeating: 0, count: x.count)
        vDSPConvolve(x, ir, &y)
        return (0..<x.count).map { i in
            let wet = i >= delay ? y[i - delay] : 0
            return tanh(0.3 * wet * 1.5) / 1.5 + Float.random(in: -0.0005...0.0005)
        }
    }

    func vDSPConvolve(_ x: [Float], _ h: [Float], _ y: inout [Float]) {
        // Direct form on the sparse early part keeps this simple; 120 ms IR at 48 kHz.
        for i in 0..<x.count where x[i] != 0 {
            let top = min(h.count, x.count - i)
            for k in stride(from: 0, to: top, by: 1) { y[i + k] += x[i] * h[k] }
        }
    }

    func sung(notes: [Double], each: Double, vibrato: Bool) -> [Float] {
        var out: [Float] = []
        for m in notes {
            let f = 440 * pow(2, (m - 69) / 12), count = Int(each * Self.rate)
            var phase = 0.0
            for i in 0..<count {
                let t = Double(i) / Self.rate
                phase += 2 * .pi * f * (vibrato ? pow(2, 30 * sin(2 * .pi * 5.5 * t) / 1_200) : 1) / Self.rate
                let edge = min(1, min(Double(i), Double(count - i)) / (0.02 * Self.rate))
                out.append(Float(0.25 * edge * (sin(phase) + 0.5 * sin(2 * phase) + 0.25 * sin(3 * phase)) / 1.75))
            }
            out += [Float](repeating: 0, count: Int(0.03 * Self.rate))
        }
        return out
    }

    func beatbox(hits: Int) -> [Float] {
        var out = [Float](repeating: 0, count: Int(Double(hits) * 0.25 * Self.rate))
        var s: UInt64 = 17
        for h in 0..<hits {
            let start = Int(Double(h) * 0.25 * Self.rate)
            for j in 0..<Int(0.05 * Self.rate) where start + j < out.count {
                s = s &* 6364136223846793005 &+ 1442695040888963407
                out[start + j] += (Float(s >> 40) / Float(1 << 24) - 0.5) * 0.6 * Float(exp(-Double(j) / Self.rate / 0.015))
            }
        }
        return out
    }

    func speech(_ text: String) throws -> [Float] {
        let aiff = FileManager.default.temporaryDirectory.appendingPathComponent("hm-e2e-say-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: aiff) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["--file-format=WAVE", "--data-format=LEF32@48000", "-o", aiff.path, text]
        try say.run(); say.waitUntilExit()
        let file = try AVAudioFile(forReading: aiff)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buf)
        return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))).map { $0 * 0.6 }
    }

    func rms(_ x: [Float]) -> Float { sqrt(x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count))) }
}
