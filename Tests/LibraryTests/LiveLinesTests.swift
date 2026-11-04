import XCTest
@testable import Library

final class LiveLinesTests: XCTestCase {
    func testWhisperNonLyricsAreJunk() {
        for t in ["*sad music*", "[Music]", "(applause)", "♪", " ♪ ♪ ", "[BLANK_AUDIO]", "(humming)", "*upbeat music*", ""] {
            XCTAssertTrue(LiveLines.isJunk(t), t)
        }
        for t in ["Yo yo yo", "music in my head tonight", "I been counting all the cars", "Singing in the rain"] {
            XCTAssertFalse(LiveLines.isJunk(t), t)
        }
    }

    func testLiveLinesSurviveAndJunkNeverShows() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hm-live-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        LiveLines.append(LiveLine(text: "yo yo yo", at: 2, end: 3.5), to: folder)
        LiveLines.append(LiveLine(text: "streetlights humming in a minor key", at: 5, end: 8), to: folder)
        // A take over the second line whose transcription was junk: the live line must stay.
        let take = #"{"chords": [], "confidence": 0, "createdAt": "2026-10-12T23:53:20Z", "daw": "Jam", "durationSeconds": 6, "files": {"voice": "t1__voice.m4a"}, "id": "t1", "key": {"confidence": 0.9937422, "mode": "minor", "tonic": 10}, "kind": "playing", "lyrics": {"text": "*sad music*", "words": [{"end": 1.5, "start": 1.0, "text": "*sad"}, {"end": 1.5, "start": 1.0, "text": "music"}, {"end": 1.5, "start": 1.0, "text": "*"}]}, "notes": 3, "padding": 1.5, "route": "speakers", "sessionStartSeconds": 4, "tempo": {"bpm": 157.4, "confidence": 0.17028578207389664}}"#
        try take.data(using: .utf8)!.write(to: folder.appendingPathComponent("t1.json"))
        let s = LabSessionExport.session(folder: folder)
        XCTAssertEqual(s.takes.count, 1, "the take must load for this to test anything")
        let texts = s.slots.flatMap { $0.map(\.text) }
        XCTAssertEqual(texts, ["yo yo yo", "streetlights humming in a minor key"])
        XCTAssertGreaterThanOrEqual(s.length, 8)
    }
}

final class PourTests: XCTestCase {
    func testWhisperWordsFollowLiveLineBreaks() {
        let whisper = "yeah, you know, we got killer flows, and all that stuff, so, just relax, and, you'll be able to, get on more tracks, and, that's a fact, so, get back".split(separator: " ").map(String.init)
        let live = [["Yeah", "you", "know", "we", "got", "killer", "flows", "and", "all", "that", "stuff"], ["so"],
                    ["just", "relax", "and", "you'll", "be", "able", "to", "get", "on", "more", "tracks"]]
        let r = LabSessionExport.pourSplit(whisper, into: live)
        XCTAssertEqual(r.lines[0].joined(separator: " "), "yeah, you know, we got killer flows, and all that stuff,")
        XCTAssertEqual(r.lines[1], ["so,"])
        XCTAssertEqual(r.lines[2].first, "just")
        XCTAssertEqual(r.overflow.joined(separator: " "), "and, that's a fact, so, get back")
        XCTAssertEqual(LabSessionExport.chunk(r.overflow).count, 2)
    }
}

final class LoneWordTests: XCTestCase {
    func v(_ text: String, at: Double) -> LabSession.Version {
        LabSession.Version(id: text, takeID: "t", text: text, start: at, end: at + 1, at: at, words: [], chords: [], keeper: false)
    }
    func testOneWordJoinsTheLineBefore() {
        let out = LabSessionExport.foldLoneWords([[v("about to be a good", at: 1)], [v("day", at: 2)], [v("yeah come", at: 3)]])
        XCTAssertEqual(out.map { $0[0].text }, ["about to be a good day", "yeah come"], "two words stand alone")
        XCTAssertEqual(LabSessionExport.foldLoneWords([[v("yo", at: 0)], [v("my name is Nate", at: 1)]]).map { $0[0].text }, ["yo my name is Nate"])
    }
}

final class VersionTests: XCTestCase {
    func v(_ text: String, at: Double) -> LabSession.Version {
        LabSession.Version(id: "\(at)", takeID: "t", text: text, start: 0, end: 1, at: at, words: [], chords: [], keeper: false)
    }
    func testALoopWithWordsSwappedIsOneLineWithVersions() {
        let out = LabSessionExport.groupVersions([
            [v("streetlights humming in a minor key", at: 1)], [v("counting all the cars that never stop", at: 4)],
            [v("streetlights buzzing in a minor key", at: 8)], [v("counting every car that never stops", at: 11)],
            [v("headlights humming in a major key", at: 15)], [v("something totally new", at: 19)]])
        XCTAssertEqual(out.map(\.count), [3, 2, 1])
    }
}

final class LiveLineConcurrencyTests: XCTestCase {
    func testLargePastePreservesEveryLineAndExistingCorrections() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        LiveLines.append(LiveLine(text: "old words", at: 1, end: 2, fixed: "kept correction"), to: folder)
        let text = (0..<300).map { "Line \($0) — café under the moon" }
        let start = ProcessInfo.processInfo.systemUptime
        LiveLines.type(text.joined(separator: "\n\n"), at: 10, to: folder)
        print("PASTE_BENCH_300_MS=\((ProcessInfo.processInfo.systemUptime - start) * 1000)")
        let saved = LiveLines.read(folder)
        XCTAssertEqual(saved.first?.fixed, "kept correction")
        XCTAssertEqual(saved.dropFirst().map(\.text), text)
        XCTAssertTrue(saved.dropFirst().allSatisfy { $0.typed == true })
        XCTAssertEqual(saved.last!.at, 12.99, accuracy: 0.0001)
    }

    func testConcurrentAppendsKeepEveryLine() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let group = DispatchGroup()
        for worker in 0..<2 {
            DispatchQueue.global().async(group: group) {
                for i in 0..<40 {
                    LiveLines.append(LiveLine(text: "worker \(worker) line \(i)", at: Double(worker * 40 + i), end: 100), to: folder)
                }
            }
        }
        group.wait()
        let lines = LiveLines.read(folder)
        XCTAssertEqual(lines.count, 80)
        XCTAssertEqual(Set(lines.map(\.text)).count, 80)
    }
}
