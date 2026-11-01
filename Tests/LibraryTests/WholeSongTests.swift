import AVFoundation
import XCTest
@testable import Library

final class WholeSongTests: XCTestCase {
    func v(_ id: String, _ text: String, at: Double, dur: Double, keeper: Bool = false, take: String = "t1") -> LabSession.Version {
        LabSession.Version(id: id, takeID: take, text: text, start: 0, end: dur, at: at, words: [], chords: [], keeper: keeper)
    }

    func testShownIsStarElseNewest() {
        XCTAssertEqual(WholeSong.shown([v("a", "x", at: 1, dur: 1), v("b", "x", at: 9, dur: 1)])?.id, "b")
        XCTAssertEqual(WholeSong.shown([v("a", "x", at: 1, dur: 1, keeper: true), v("b", "x", at: 9, dur: 1)])?.id, "a")
    }

    func testLinesSungBackToBackStayOneClip() {
        let slots = [[v("1", "first line here", at: 10, dur: 2)],
                     [v("2", "second line here", at: 12.5, dur: 2)],
                     [v("3", "much later line", at: 60, dur: 3)]]
        let clips = WholeSong.plan(slots)
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips[0].lines, ["first line here", "second line here"])
        XCTAssertEqual(clips[0].start, 9.75, accuracy: 0.001)
        XCTAssertEqual(clips[0].end, 15.1, accuracy: 0.001)
        XCTAssertEqual(clips[1].lines, ["much later line"])
    }

    func testNewestVersionOfAnEarlierLineStartsItsOwnClip() {
        // Line 1 re-sung at 80 s (newest shown), line 2 only sung at 20 s: two clips, in notebook order.
        let slots = [[v("1a", "first line", at: 10, dur: 2), v("1b", "first line again", at: 80, dur: 2)],
                     [v("2", "second line", at: 20, dur: 2)]]
        let clips = WholeSong.plan(slots)
        XCTAssertEqual(clips.map(\.lines), [["first line again"], ["second line"]])
    }

    func testHumsChordsAndTypedLinesStayOut() {
        let slots = [[v("hum-t1", "hum · A3 C4", at: 1, dur: 2)],
                     [v("chords-t1-10", "chords C G", at: 3, dur: 2)],
                     [LabSession.Version(id: "live-1", takeID: "typed", text: "typed", start: 0, end: 1, at: 5, words: [], chords: [], keeper: false)],
                     [v("x", "sung words", at: 7, dur: 2)]]
        XCTAssertEqual(WholeSong.plan(slots).map(\.lines), [["sung words"]])
    }

    func testAWholeSectionBeatsANewerSingleLine() {
        // A, B, C sung as one pass at 10–16 s; B re-sung alone at 50 s. The song plays the pass straight through.
        let slots = [[v("a", "line a here", at: 10, dur: 2)],
                     [v("b1", "line b here", at: 12, dur: 2), v("b2", "line b again", at: 50, dur: 2)],
                     [v("c", "line c here", at: 14, dur: 2)]]
        XCTAssertEqual(WholeSong.plan(slots).map(\.lines), [["line a here", "line b here", "line c here"]])
    }

    func testAStarredVersionAlwaysWinsItsLine() {
        let slots = [[v("a", "line a here", at: 10, dur: 2)],
                     [v("b1", "line b here", at: 12, dur: 2), v("b2", "line b again", at: 50, dur: 2, keeper: true)],
                     [v("c", "line c here", at: 14, dur: 2)]]
        XCTAssertEqual(WholeSong.plan(slots).map(\.lines), [["line a here"], ["line b again"], ["line c here"]])
    }

    func testLinesPlayInTheOrderTheyWereFirstSung() {
        // The notebook can list a line before an earlier one; the song goes by when each was first sung.
        let slots = [[v("2", "second idea here", at: 40, dur: 2)], [v("1", "first idea here", at: 5, dur: 2)]]
        XCTAssertEqual(WholeSong.plan(slots).map(\.lines), [["first idea here"], ["second idea here"]])
    }

    func testChatterIsNeverPartOfTheSong() {
        let slots = [[v("1", "you pull your hair back when you see me", at: 10, dur: 3)],
                     [v("2", "let me get some ad-libs real quick", at: 14, dur: 2)],
                     [v("3", "my bad", at: 30, dur: 1)]]
        XCTAssertEqual(WholeSong.plan(slots).map(\.lines), [["you pull your hair back when you see me"]])
        XCTAssertTrue(WholeSong.isChatter("next one, next one"))
        XCTAssertFalse(WholeSong.isChatter("so when we get up in this room just know we touching"))
    }

    func testCollapsedTimingsStillGetTheirWords() {
        // Whisper gave the line no length: ~0.35 s a word keeps it in the song.
        let slots = [[LabSession.Version(id: "x", takeID: "t1", text: "one two three four five six", start: 3, end: 3, at: 20, words: [], chords: [], keeper: false)]]
        let clip = WholeSong.plan(slots)[0]
        XCTAssertEqual(clip.end - clip.start, 0.25 + 2.1 + 0.6, accuracy: 0.01)
    }

    func testRenderCutsAcrossSegmentsInOrder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wholesong-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rate = 16_000.0
        // Two 2 s segments: the first a 440 Hz tone, the second silence.
        var urls: [URL] = []
        for (k, hz) in [440.0, 0].enumerated() {
            let url = dir.appendingPathComponent(String(format: "session__mix_%03d.m4a", k + 1))
            let f = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1],
                                    commonFormat: .pcmFormatFloat32, interleaved: false)
            let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(rate * 2))!
            for i in 0..<Int(rate * 2) { buf.floatChannelData![0][i] = Float(0.5 * sin(2 * .pi * hz * Double(i) / rate)) }
            buf.frameLength = AVAudioFrameCount(rate * 2)
            try f.write(from: buf)
            urls.append(url)
        }
        let out = dir.appendingPathComponent("song.m4a")
        try WholeSong.render([.init(start: 1.5, end: 2.5, lines: ["a"]), .init(start: 0.2, end: 0.7, lines: ["b"])],
                             segments: urls, segmentSeconds: 2, to: out)
        let song = try AVAudioFile(forReading: out)
        XCTAssertEqual(Double(song.length) / rate, 1.5, accuracy: 0.1)   // 1.0 s (across the seam) + 0.5 s
    }
}
