import AVFoundation
import XCTest
@testable import Detection
@testable import Library
import Enrichment
import Timeline

final class ScratchStoreTests: XCTestCase {
    var dir: URL!
    override func setUp() { dir = FileManager.default.temporaryDirectory.appendingPathComponent("hm-scratch-\(UUID())") }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testReadsAcrossSegmentBoundaries() throws {
        let store = try ScratchStore(directory: dir, sampleRate: 100, segmentSeconds: 1, keepSegments: 5)  // 100-frame segments
        let voice = (0..<250).map { Float($0) / 1_000 }
        let mix = voice.flatMap { [$0, -$0] }
        try voice.withUnsafeBufferPointer { v in try mix.withUnsafeBufferPointer { try store.append(voice: v, mix: $0, frames: 250) } }
        let out = try store.read(from: 90, to: 210)
        XCTAssertEqual(out.voice.count, 120)
        XCTAssertEqual(out.voice.first!, 0.090, accuracy: 1e-4)
        XCTAssertEqual(out.voice.last!, 0.209, accuracy: 1e-4)
        XCTAssertEqual(out.mix[1], -0.090, accuracy: 1e-4)
    }

    func testEvictsOldSegments() throws {
        let store = try ScratchStore(directory: dir, sampleRate: 100, segmentSeconds: 1, keepSegments: 2)
        let v = [Float](repeating: 0.1, count: 500), m = [Float](repeating: 0.1, count: 1_000)
        try v.withUnsafeBufferPointer { vv in try m.withUnsafeBufferPointer { try store.append(voice: vv, mix: $0, frames: 500) } }
        XCTAssertEqual(store.oldestRetained, 300)
        XCTAssertEqual(try store.read(from: 0, to: 500).voice.count, 200)
    }
}

final class TakePipelineTests: XCTestCase {
    func sung(_ seconds: Double, rate: Double) -> [Float] {
        let notes = [220.0, 261.6, 293.7, 246.9]
        let per = Int(0.5 * rate)
        return (0..<Int(seconds * rate)).map { i in
            let f = notes[(i / per) % notes.count]
            let p = 2 * Double.pi * f * Double(i) / rate
            return Float(0.2 * (sin(p) + 0.5 * sin(2 * p)) / 1.5)
        }
    }

    /// The session that lost everything: someone singing nonstop for longer than the scratch audio goes back.
    /// All of it has to end up in takes, not just the last 12 minutes.
    func testSingingForLongerThanTheScratchWindowLosesNothing() throws {
        let rate = 16_000.0
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hm-long-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let pipeline = try TakePipeline(folder: folder, sampleRate: rate, sessionStart: Date(), daw: "Jam", jam: true)
        pipeline.judge = PitchOnlyKeepAll()
        pipeline.options = .captureOnly
        let minutes = 14, block = 4_000
        var position: Int64 = 0
        // 20 s of singing and a 1 s breath, over and over: the breaths never let the take close.
        let breath = (0..<Int(rate)).map { _ in Float.random(in: -0.0003...0.0003) }
        let tune = breath + breath + sung(20, rate: rate)
        var voice = [Float](repeating: 0, count: block), mix = [Float](repeating: 0, count: block * 2)
        while position < Int64(minutes * 60) * Int64(rate) {
            for i in 0..<block { voice[i] = tune[Int((position + Int64(i)) % Int64(tune.count))]; mix[2 * i] = voice[i]; mix[2 * i + 1] = voice[i] }
            voice.withUnsafeBufferPointer { v in mix.withUnsafeBufferPointer { pipeline.consume(voice: v, mix: $0, frames: block, position: position) } }
            position += Int64(block)
        }
        try pipeline.finish()
        pipeline.waitForExports()
        let takes = pipeline.takes.sorted { $0.sessionStartSeconds < $1.sessionStartSeconds }
        XCTAssertLessThan(takes.first?.sessionStartSeconds ?? 999, 5, "the start of the session is there")
        var covered = 0.0, end = 0.0
        for t in takes {
            XCTAssertLessThan(t.durationSeconds, 12 * 60, "no take outgrows the scratch audio")
            XCTAssertLessThanOrEqual(t.sessionStartSeconds, end + 10, "no hole in the session")
            covered += max(0, t.sessionStartSeconds + t.durationSeconds - max(end, t.sessionStartSeconds))
            end = max(end, t.sessionStartSeconds + t.durationSeconds)
        }
        XCTAssertGreaterThan(covered, Double(minutes * 60) * 0.98, "\(takes.count) takes")
    }

    private struct PitchOnlyKeepAll: PhraseJudging {
        func judge(_ samples: [Float], sampleRate: Double, detected: SingingSegment.Kind) -> SingingSegment.Kind? { .rap }
    }

    func testSungIdeaBecomesOneTakeWithBothFilesAndSidecar() throws {
        let scratchBefore = Set((try? FileManager.default.contentsOfDirectory(atPath: TakePipeline.scratchRoot.path)) ?? [])
        let rate = 48_000.0
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hm-takes-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let pipeline = try TakePipeline(folder: folder, sampleRate: rate, sessionStart: Date(), daw: "Ableton Live")

        let hiss = (0..<Int(12 * rate)).map { _ in Float.random(in: -0.0003...0.0003) }
        var voice = hiss
        let singing = sung(3, rate: rate)
        for i in singing.indices { voice[Int(4 * rate) + i] += singing[i] }   // sing at 4–7 s
        let mix = voice.flatMap { [$0 + 0.05, $0 + 0.05] }

        var position: Int64 = 0
        voice.withUnsafeBufferPointer { v in
            mix.withUnsafeBufferPointer { m in
                for start in stride(from: 0, to: v.count, by: 2_400) {
                    pipeline.consume(voice: UnsafeBufferPointer(rebasing: v[start..<(start + 2_400)]),
                                     mix: UnsafeBufferPointer(rebasing: m[(2 * start)..<(2 * start + 4_800)]),
                                     frames: 2_400, position: position)
                    position += 2_400
                }
            }
        }
        pipeline.waitForExports()
        XCTAssertEqual(pipeline.takes.count, 1, "released before session end once it could no longer grow")
        try pipeline.finish()
        XCTAssertEqual(pipeline.takes.count, 1)

        let take = try XCTUnwrap(pipeline.takes.first)
        XCTAssertEqual(take.sessionStartSeconds, 2.5, accuracy: 0.15, "1.5 s of padding before the first note")
        XCTAssertEqual(take.durationSeconds, 6.0, accuracy: 0.3)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }.sorted()
        XCTAssertEqual(files.count, take.files["tuned"] == nil ? 4 : 5, "voice, mix, json, mid (+ tuned when a key was found)")
        XCTAssertNotNil(take.files["midi"])
        XCTAssertGreaterThanOrEqual(take.notes ?? 0, 4)
        XCTAssertEqual(try AVAudioFile(forReading: folder.appendingPathComponent(take.files["mix"]!)).fileFormat.channelCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".scratch").path), "no scratch in the synced library")
        let leftovers = Set((try? FileManager.default.contentsOfDirectory(atPath: TakePipeline.scratchRoot.path)) ?? [])
        XCTAssertTrue(leftovers.subtracting(scratchBefore).isEmpty, "session scratch removed from the cache folder")
    }
}

final class TakeStampTests: XCTestCase {
    func testFilenameAndSidecarCarryBarAndTempo() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hm-stamp-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let scratch = try ScratchStore(directory: folder.appendingPathComponent(".scratch"), sampleRate: 48_000)
        let v = [Float](repeating: 0.1, count: 240_000), m = [Float](repeating: 0.1, count: 480_000)
        try v.withUnsafeBufferPointer { vv in try m.withUnsafeBufferPointer { try scratch.append(voice: vv, mix: $0, frames: 240_000) } }

        var exporter = TakeExporter(folder: folder, sampleRate: 48_000, sessionStart: Date(), daw: "Ableton Live")
        var asked: Int64 = -1
        exporter.positionAt = { frame in
            asked = frame
            return MusicalPosition(bar: 33, beat: 1, sixteenth: 1, tempo: 127.96, beatsPerBar: 4, playing: true)
        }
        let record = try XCTUnwrap(exporter.export(TakeRange(start: 48_000, end: 192_000, confidence: 0.9, padding: 1.5),
                                                   from: scratch, route: "headphones"))
        XCTAssertEqual(asked, 120_000, "stamped at the first sung note, not the padding")
        XCTAssertTrue(record.id.contains("_Ableton-Live_bar-33_128bpm"), record.id)
        XCTAssertEqual(record.position?.bar, 33)
    }
}

struct StubTranscriber: LyricTranscribing {
    func transcribe(_ samples: [Float], sampleRate: Double) async throws -> Lyrics {
        Lyrics(text: "paper moon over the river", words: [.init(text: "paper", start: 0.1, end: 0.4)])
    }
}

final class LyricsPipelineTests: XCTestCase {
    func testSungTakeGetsLyricsInSidecarAndSessionSheet() async throws {
        let rate = 48_000.0
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hm-lyrics-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let pipeline = try TakePipeline(folder: folder, sampleRate: rate, sessionStart: Date(), daw: "Ableton Live")
        pipeline.transcriber = StubTranscriber()
        pipeline.catalog = { LyricIndex([.init(id: "old", title: "Neon Rivers", text: "paper moon over the river tonight")]) }
        let got = expectation(description: "lyrics callback")
        pipeline.onLyrics = { _, lyrics in if lyrics.text.contains("paper moon") { got.fulfill() } }

        var voice = (0..<Int(10 * rate)).map { _ in Float.random(in: -0.0003...0.0003) }
        let sung = TakePipelineTests().sung(3, rate: rate)
        for i in sung.indices { voice[Int(2 * rate) + i] += sung[i] }
        let mix = voice.flatMap { [$0, $0] }
        voice.withUnsafeBufferPointer { v in
            mix.withUnsafeBufferPointer { m in
                for start in stride(from: 0, to: v.count, by: 2_400) {
                    pipeline.consume(voice: UnsafeBufferPointer(rebasing: v[start..<(start + 2_400)]),
                                     mix: UnsafeBufferPointer(rebasing: m[(2 * start)..<(2 * start + 4_800)]),
                                     frames: 2_400, position: Int64(start))
                }
            }
        }
        try pipeline.finish()
        await pipeline.waitForLyrics()
        await fulfillment(of: [got], timeout: 5)

        let id = try XCTUnwrap(pipeline.takes.first?.id)
        let record = try LyricSheet.decoder.decode(TakeRecord.self, from: Data(contentsOf: folder.appendingPathComponent("\(id).json")))
        XCTAssertEqual(record.lyrics?.words.first?.text, "paper")
        let sheet = try String(contentsOf: folder.appendingPathComponent(LyricSheet.fileName), encoding: .utf8)
        XCTAssertTrue(sheet.contains("paper moon over the river"))
        XCTAssertEqual(record.echoes?.first?.from, "Neon Rivers", "recognized as a line from an earlier song")
        XCTAssertTrue(sheet.contains("already in Neon Rivers"))
    }
}

final class FreeTierExportTests: XCTestCase {
    func testFreeTakesAreJustTheTwoRecordingsAndSidecar() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hm-free-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let scratch = try ScratchStore(directory: folder.appendingPathComponent(".scratch"), sampleRate: 48_000)
        let voice = TakePipelineTests().sung(4, rate: 48_000)
        let mix = voice.flatMap { [$0, $0] }
        try voice.withUnsafeBufferPointer { v in try mix.withUnsafeBufferPointer { try scratch.append(voice: v, mix: $0, frames: voice.count) } }
        var exporter = TakeExporter(folder: folder, sampleRate: 48_000, sessionStart: Date(), daw: "Ableton Live")
        exporter.options = .captureOnly
        let record = try XCTUnwrap(exporter.export(TakeRange(start: 0, end: Int64(voice.count), confidence: 1), from: scratch, route: "headphones"))
        XCTAssertEqual(Set(record.files.keys), ["voice", "mix"])
        XCTAssertNil(record.key)
        XCTAssertNil(record.section)
    }
}

final class PreviewMuteTests: XCTestCase {
    func testPreviewPlaybackNeverBecomesATake() throws {
        let rate = 48_000.0
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hm-mute-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let pipeline = try TakePipeline(folder: folder, sampleRate: rate, sessionStart: Date(), daw: "Ableton Live")
        var voice = (0..<Int(10 * rate)).map { _ in Float.random(in: -0.0003...0.0003) }
        let sung = TakePipelineTests().sung(3, rate: rate)
        for i in sung.indices { voice[Int(2 * rate) + i] += sung[i] }   // the mic hears the preview at 2–5 s
        let mix = voice.flatMap { [$0, $0] }
        voice.withUnsafeBufferPointer { v in
            mix.withUnsafeBufferPointer { m in
                for start in stride(from: 0, to: v.count, by: 2_400) {
                    if start == Int(1.9 * rate) / 2_400 * 2_400 { pipeline.muteDetection(for: 4) }  // preview starts
                    pipeline.consume(voice: UnsafeBufferPointer(rebasing: v[start..<(start + 2_400)]),
                                     mix: UnsafeBufferPointer(rebasing: m[(2 * start)..<(2 * start + 4_800)]),
                                     frames: 2_400, position: Int64(start))
                }
            }
        }
        try pipeline.finish()
        XCTAssertEqual(pipeline.takes.count, 0)
    }
}

final class LongTakeClampTests: XCTestCase {
    func testTakeOlderThanScratchKeepsHonestStart() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hm-clamp-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let scratch = try ScratchStore(directory: folder.appendingPathComponent(".scratch"), sampleRate: 48_000,
                                       segmentSeconds: 1, keepSegments: 3)
        let v = [Float](repeating: 0.1, count: 48_000 * 6), m = [Float](repeating: 0.1, count: 96_000 * 6)
        try v.withUnsafeBufferPointer { vv in try m.withUnsafeBufferPointer { try scratch.append(voice: vv, mix: $0, frames: v.count) } }
        var exporter = TakeExporter(folder: folder, sampleRate: 48_000, sessionStart: Date(), daw: "Ableton Live")
        exporter.options = .captureOnly
        let record = try XCTUnwrap(exporter.export(TakeRange(start: 0, end: 48_000 * 6, confidence: 1, padding: 1.5),
                                                   from: scratch, route: "headphones"))
        XCTAssertEqual(record.sessionStartSeconds, 3, accuracy: 0.01, "starts where scratch still has audio")
        XCTAssertEqual(record.durationSeconds, 3, accuracy: 0.01)
    }
}

final class UniqueTakeNameTests: XCTestCase {
    func testTwoTakesInTheSameSecondGetDistinctFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hm-uniq-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let scratch = try ScratchStore(directory: folder.appendingPathComponent(".s"), sampleRate: 48_000)
        let v = [Float](repeating: 0.1, count: 96_000), m = [Float](repeating: 0.1, count: 192_000)
        try v.withUnsafeBufferPointer { vv in try m.withUnsafeBufferPointer { try scratch.append(voice: vv, mix: $0, frames: 96_000) } }
        var exporter = TakeExporter(folder: folder, sampleRate: 48_000, sessionStart: Date(timeIntervalSince1970: 1_800_000_000), daw: "Ableton Live")
        exporter.options = .captureOnly
        let a = try XCTUnwrap(exporter.export(TakeRange(start: 0, end: 48_000, confidence: 1), from: scratch, route: "x"))
        let b = try XCTUnwrap(exporter.export(TakeRange(start: 100, end: 48_100, confidence: 1), from: scratch, route: "x"))
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a.files["voice"], b.files["voice"])
    }
}

final class JamExportTests: XCTestCase {
    /// Strummed chords, one strum per beat, decaying like a guitar.
    static func strums(_ chords: [[Int]], bpm: Double, beatsPerChord: Int, rate: Double, level: Float) -> [Float] {
        let beat = Int(60 / bpm * rate)
        var out: [Float] = []
        for chord in chords {
            for _ in 0..<beatsPerChord {
                out += (0..<beat).map { i in
                    let t = Double(i) / rate, env = Float(exp(-t / 0.25))
                    var s: Double = 0
                    for m in chord {
                        let f = 440 * pow(2, Double(m - 69) / 12)
                        s += sin(2 * .pi * f * t) + 0.4 * sin(4 * .pi * f * t) + 0.2 * sin(6 * .pi * f * t)
                    }
                    return level * env * Float(s) / Float(chord.count)
                }
            }
        }
        return out
    }

    func testQuietJamTakeComesOutLoudWithChordsAndTempo() throws {
        let rate = 48_000.0
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hm-jam-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let c = [48, 52, 55, 60, 64], am = [45, 52, 57, 60, 64], f = [41, 48, 53, 57, 60], g = [43, 47, 50, 55, 59]
        let mic = Self.strums([c, am, f, g, c, am, f, g], bpm: 100, beatsPerChord: 4, rate: rate, level: 0.02)
        let mix = mic.flatMap { [$0, $0] }
        let scratch = try ScratchStore(directory: folder.appendingPathComponent(".scratch"), sampleRate: rate)
        try mic.withUnsafeBufferPointer { v in try mix.withUnsafeBufferPointer { try scratch.append(voice: v, mix: $0, frames: mic.count) } }
        var exporter = TakeExporter(folder: folder, sampleRate: rate, sessionStart: Date(), daw: "Jam")
        exporter.jam = true
        let record = try XCTUnwrap(exporter.export({ var r = TakeRange(start: 0, end: Int64(mic.count), confidence: 1); r.kind = .playing; return r }(), from: scratch, route: "mic"))

        XCTAssertEqual(try XCTUnwrap(record.tempo).bpm, 100, accuracy: 2)
        XCTAssertTrue(record.id.contains("_100bpm"), record.id)
        XCTAssertEqual(record.key?.short, "Cmaj")
        XCTAssertEqual(record.chords?.map(\.name), ["C", "Am", "F", "G", "C", "Am", "F", "G"])
        XCTAssertNil(record.files["tuned"], "no auto-tuned guitar")
        XCTAssertNotNil(record.files["midi"], "every note of the jam as MIDI (Basic Pitch)")
        XCTAssertGreaterThan(record.notes ?? 0, 30, "chords are polyphonic: several notes per strum")

        // Played at −40 dBFS-ish, saved at a playable level without clipping.
        let file = try AVAudioFile(forReading: folder.appendingPathComponent(try XCTUnwrap(record.files["voice"])))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let saved = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let inRMS = sqrt(mic.reduce(0) { $0 + $1 * $1 } / Float(mic.count))
        let outRMS = sqrt(saved.reduce(0) { $0 + $1 * $1 } / Float(saved.count))
        XCTAssertGreaterThan(20 * log10(outRMS / inRMS), 15, "boosted")
        XCTAssertLessThanOrEqual(saved.map(abs).max() ?? 0, 0.95, "limited")
    }
}

struct KeepEverythingJudge: PhraseJudging {
    func judge(_ samples: [Float], sampleRate: Double, detected: SingingSegment.Kind) -> SingingSegment.Kind? { .playing }
}

final class JamPipelineTests: XCTestCase {
    func run(_ mic: [Float], judge: PhraseJudging? = nil) throws -> [TakeRecord] {
        let rate = 48_000.0
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hm-jampipe-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let pipeline = try TakePipeline(folder: folder, sampleRate: rate, sessionStart: Date(), daw: "Jam", jam: true)
        if let judge { pipeline.judge = judge }
        var noisy = mic
        for i in noisy.indices { noisy[i] += Float.random(in: -0.0002...0.0002) }
        let mix = noisy.flatMap { [$0, $0] }
        noisy.withUnsafeBufferPointer { v in
            mix.withUnsafeBufferPointer { m in
                for start in stride(from: 0, to: v.count - 2_400, by: 2_400) {
                    pipeline.consume(voice: UnsafeBufferPointer(rebasing: v[start..<(start + 2_400)]),
                                     mix: UnsafeBufferPointer(rebasing: m[(2 * start)..<(2 * start + 4_800)]),
                                     frames: 2_400, position: Int64(start))
                }
            }
        }
        try pipeline.finish()
        return pipeline.takes.sorted { $0.sessionStartSeconds < $1.sessionStartSeconds }
    }

    func testAPauseToThinkStaysInOneTakeButABreakSplits() throws {
        let rate = 48_000.0
        let c = [48, 52, 55, 60, 64], g = [43, 47, 50, 55, 59]
        let verse = JamExportTests.strums([c, g, c, g], bpm: 100, beatsPerChord: 4, rate: rate, level: 0.05)
        let silence = { (s: Double) in [Float](repeating: 0, count: Int(s * rate)) }
        let mic = silence(2) + verse + silence(3) + verse + silence(15) + verse + silence(10)
        let takes = try run(mic, judge: KeepEverythingJudge())
        XCTAssertEqual(takes.count, 2, takes.map(\.id).description)
        XCTAssertEqual(takes.first?.kind, "playing")
        XCTAssertGreaterThan(takes.first?.durationSeconds ?? 0, 20, "verse + 3 s pause + verse")
    }

    func testJudgeKeepsMusicAndDropsTalk() {
        typealias S = AppleVoiceJudge.Scores
        XCTAssertEqual(JamJudge.decide(S(singing: 0.2, speech: 0.1, music: 0.7)), .playing)
        XCTAssertEqual(JamJudge.decide(S(singing: 0.6, speech: 0.2, music: 0.1)), .singing)
        XCTAssertEqual(JamJudge.decide(S(speech: 0.8, music: 0.1)), .rap, "rap and talk-like bars are kept in Freestyle")
        XCTAssertEqual(JamJudge.decide(S(speech: 0.3, whisper: 0.2)), .whisper)
        XCTAssertNil(JamJudge.decide(S(speech: 0.05, music: 0.02)), "silence / room noise")
        XCTAssertEqual(JamJudge.decide(S(speech: 0.5, music: 0.4, instrument: 0.5)), .playing, "singing-talking over the guitar still counts")
        XCTAssertEqual(JamJudge.decide(S(speech: 0.56, music: 0.40, instrument: 0.15)), .rap, "rap alone scores 'music' but names no instrument (Nate 2026-10-13)")
    }

    func testAppleClassifierHearsStrumsAsMusic() throws {
        let strums = JamExportTests.strums([[48, 52, 55, 60, 64], [45, 52, 57, 60, 64]], bpm: 100, beatsPerChord: 4, rate: 48_000, level: 0.1)
        let scores = try XCTUnwrap(AppleVoiceJudge().scores(strums, sampleRate: 48_000))
        print("strum scores:", scores)
        XCTAssertEqual(JamJudge.decide(scores), .playing)
    }
}

final class WhisperTakeTests: XCTestCase {
    /// Whispering a line ~35 dB down in a quiet room becomes a whisper take.
    func testQuietWhisperBecomesATake() throws {
        let rate = 48_000.0
        let aiff = FileManager.default.temporaryDirectory.appendingPathComponent("hm-wt-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: aiff) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Whisper", "-r", "150", "-o", aiff.path, "--data-format=LEF32@48000",
                         "I keep your letters in a coat by the door, burning slow, burning slow"]
        try say.run(); say.waitUntilExit()
        let file = try AVAudioFile(forReading: aiff)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let whisper = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let peak = whisper.map(abs).max() ?? 1
        var mic = (0..<Int(12 * rate)).map { _ in Float.random(in: -0.0003...0.0003) }   // quiet room
        for i in whisper.indices where Int(2 * rate) + i < mic.count { mic[Int(2 * rate) + i] += whisper[i] / peak * 0.02 }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hm-wtake-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let pipeline = try TakePipeline(folder: folder, sampleRate: rate, sessionStart: Date(), daw: "Ableton Live")
        pipeline.judge = AppleVoiceJudge()
        let mix = mic.flatMap { [$0, $0] }
        mic.withUnsafeBufferPointer { v in
            mix.withUnsafeBufferPointer { m in
                for start in stride(from: 0, to: v.count - 2_400, by: 2_400) {
                    pipeline.consume(voice: UnsafeBufferPointer(rebasing: v[start..<(start + 2_400)]),
                                     mix: UnsafeBufferPointer(rebasing: m[(2 * start)..<(2 * start + 4_800)]),
                                     frames: 2_400, position: Int64(start))
                }
            }
        }
        try pipeline.finish()
        XCTAssertEqual(pipeline.takes.map(\.kind), ["whisper"], pipeline.takes.map(\.id).description)
    }
}
