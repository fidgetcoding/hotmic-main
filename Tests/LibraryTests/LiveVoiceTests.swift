import XCTest
import Enrichment
@testable import Library

/// The live recognizer's rules on sound (2026-10-13 and 10-14 fixes), with no recognizer and no microphone.
final class LiveVoiceTests: XCTestCase {
    private let rate = 16_000.0
    private func tone(_ seconds: Double, level: Float) -> [Float] {
        (0..<Int(seconds * rate)).map { level * sin(2 * .pi * 220 * Float($0) / Float(rate)) }
    }

    func testAMumbleCountsAsSoundAndARoomDoesNot() {
        let mumble = tone(2, level: 0.05), room = tone(2, level: 0.001)   // about −30 dB and −60 dB
        XCTAssertTrue(LiveVoice.isVoiced(mumble[...], rate: rate))
        XCTAssertFalse(LiveVoice.isVoiced(room[...], rate: rate))
    }

    func testASpeckOfSoundInAPauseIsStillAPause() {
        let x = tone(0.2, level: 0.05) + tone(1.8, level: 0.001)
        XCTAssertFalse(LiveVoice.isVoiced(x[...], rate: rate), "a third of the frames have to have sound")
    }

    func testTooShortToSay() {
        XCTAssertFalse(LiveVoice.isVoiced([Float](repeating: 0.5, count: 10)[...], rate: rate))
    }

    func testARequestThatHeardNothingThroughSingingIsStuck() {
        let singing = tone(6, level: 0.05)
        XCTAssertTrue(LiveVoice.isStuck(heardAnything: false, secondsSinceStart: 6, recent: singing[...], rate: rate))
    }

    func testARequestIsNotStuckWhenItHeardWordsOrItIsEarlyOrItIsQuiet() {
        let singing = tone(6, level: 0.05), quiet = tone(6, level: 0.001), short = tone(2, level: 0.05)
        XCTAssertFalse(LiveVoice.isStuck(heardAnything: true, secondsSinceStart: 6, recent: singing[...], rate: rate))
        XCTAssertFalse(LiveVoice.isStuck(heardAnything: false, secondsSinceStart: 2, recent: singing[...], rate: rate))
        XCTAssertFalse(LiveVoice.isStuck(heardAnything: false, secondsSinceStart: 6, recent: quiet[...], rate: rate))
        XCTAssertFalse(LiveVoice.isStuck(heardAnything: false, secondsSinceStart: 6, recent: short[...], rate: rate), "under 2.5 s of sound")
    }

    func testAClipReachesBackButNotIntoTheLineBefore() {
        XCTAssertEqual(LiveVoice.clipStart(lineStart: 10, previousLineEnd: 2), 8.6, accuracy: 0.001)
        XCTAssertEqual(LiveVoice.clipStart(lineStart: 10, previousLineEnd: 9.5), 9.5)
        XCTAssertEqual(LiveVoice.clipStart(lineStart: 0.5, previousLineEnd: -.infinity), -0.9, accuracy: 0.001, "the first line: reading clamps it to the start")
    }
}

/// The rest of the 2026-10-14 changes that were only ever tried by hand.
final class October14Tests: XCTestCase {
    private func take(_ id: String, at: Double, kind: String, lyrics: String? = nil, chords: [String] = []) -> TakeRecord {
        var r = TakeRecord(id: id, createdAt: Date(), daw: "Jam", sessionStartSeconds: at, durationSeconds: 8, confidence: 1, route: "mic", files: [:])
        r.kind = kind
        let spans = chords.enumerated().map { #"{"name":"\#($1)","start":\#($0),"end":\#($0 + 1),"confidence":1}"# }.joined(separator: ",")
        r.chords = try? JSONDecoder().decode([ChordSpan].self, from: Data("[\(spans)]".utf8))
        if let lyrics {
            var t = 0.0
            r.lyrics = Lyrics(text: lyrics, words: lyrics.split(separator: " ").map { w in defer { t += 0.5 }; return Lyrics.Word(text: String(w), start: t, end: t + 0.4) })
        }
        return r
    }

    func testChordsShowOnlyWhereAnInstrumentPlayed() {
        let rap = take("rap", at: 0, kind: "rap", lyrics: "moonlight on my new song tonight", chords: ["Am", "F"])
        let played = take("gtr", at: 20, kind: "playing", lyrics: "velvet rain on the window pane", chords: ["Am", "F"])
        let slots = LyricArranger.arrange(takes: [rap, played], keepers: [], live: []).flatMap { $0 }
        XCTAssertEqual(slots.first { $0.takeID == "rap" }?.chords, [], "someone talking or rapping has no chords")
        XCTAssertFalse(slots.first { $0.takeID == "gtr" }?.chords.isEmpty ?? true)
    }

    func testBeatRunsAreKeptInOrderBesideTheSession() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(BeatRuns.read(folder), [])
        let a = BeatRun(at: 0, beat: 4, loopA: 0, loopB: 8, loopOn: true, beatName: "one.wav"), b = BeatRun(at: 30, beat: 0, loopA: 0, loopB: 0, loopOn: false)
        BeatRuns.append(a, to: folder); BeatRuns.append(b, to: folder)
        XCTAssertEqual(BeatRuns.read(folder), [a, b])
        XCTAssertEqual(LabSessionExport.session(folder: folder).beatRuns, [a, b], "the window gets them")
    }

    func testAWrittenSessionHoldsTypedLinesExactlyAsTyped() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        LiveLines.type("One word\nyeah come around, Mr. Jones.\n\n  third line  ", at: 3, to: folder)
        let session = LabSessionExport.session(folder: folder)
        XCTAssertEqual(session.slots.map { $0[0].text }, ["One word", "yeah come around, Mr. Jones.", "third line"], "never cleaned up, folded or recut")
        XCTAssertTrue(session.slots.allSatisfy { $0[0].takeID == "typed" })
        XCTAssertEqual(WholeSong.plan(session.slots), [], "no audio behind them, so not in the whole song")
        XCTAssertEqual(session.slots.map { $0[0].at }, [3, 3.01, 3.02])
    }

    func testDeletingAndUndoingOutOfOrderStaysConsistent() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        HiddenRanges.hide(HiddenRange(a: 1, b: 2), in: folder)
        HiddenRanges.hide(HiddenRange(a: 5, b: 6), in: folder)
        HiddenRanges.unhideLast(in: folder)
        XCTAssertEqual(HiddenRanges.read(folder), [HiddenRange(a: 1, b: 2)])
        HiddenRanges.unhideLast(in: folder)
        HiddenRanges.unhideLast(in: folder)      // nothing left: no harm
        XCTAssertEqual(HiddenRanges.read(folder), [])
    }
}
