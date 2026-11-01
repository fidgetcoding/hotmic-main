import XCTest
@testable import Detection
import Enrichment
@testable import Library

/// Hums and beatboxing (no words) get their own notepad rows (Nate 2026-10-13).
final class WordlessRowsTests: XCTestCase {
    func take(_ id: String, at: Double, kind: String, lyrics: String? = nil, notes: [Int] = []) -> TakeRecord {
        var r = TakeRecord(id: id, createdAt: Date(), daw: "Jam", sessionStartSeconds: at, durationSeconds: 4,
                           confidence: 1, route: "mic", files: [:], position: nil)
        r.kind = kind
        if let lyrics { r.lyrics = Lyrics(text: lyrics, words: []) }
        r.midiNotes = notes.enumerated().map { Note(pitch: $0.element, sungPitch: Double($0.element), start: Double($0.offset) * 0.5, duration: 0.4, velocity: 90) }
        return r
    }
    func line(_ text: String, at: Double, takeID: String = "") -> LabSession.Version {
        LabSession.Version(id: text, takeID: takeID, text: text, start: 0, end: 1, at: at, words: [], chords: [], keeper: false)
    }

    func testHumAndBeatGetRowsInTimeOrder() {
        let rows = LabSessionExport.wordless([take("h", at: 5, kind: "singing", notes: [57, 60, 64]), take("b", at: 20, kind: "beatbox")],
                                             into: [[line("first line", at: 1)], [line("later line", at: 12)]])
        XCTAssertEqual(rows.map { $0[0].text }, ["first line", "hum · A3 C4 E4", "later line", "beat"])
        XCTAssertEqual(rows[1][0].takeID, "h")
        XCTAssertEqual(rows[1][0].words.map(\.w), ["A3", "C4", "E4"])
    }

    func testTakesWithWordsOrUnderLiveLinesOrPlayingAreLeftAlone() {
        let rows = LabSessionExport.wordless([take("w", at: 2, kind: "singing", lyrics: "hello there"),
                                              take("u", at: 10, kind: "singing"),
                                              take("p", at: 30, kind: "playing")],
                                             into: [[line("covered", at: 11)]])
        XCTAssertEqual(rows.map { $0[0].text }, ["covered"])
    }

    func testHumWithoutMelodyStillShows() {
        XCTAssertEqual(LabSessionExport.wordless([take("h", at: 0, kind: "singing")], into: []).map { $0[0].text }, ["hum"])
    }

    func testFreestyleJudgeHearsDrumHitsAsBeatbox() {
        typealias S = AppleVoiceJudge.Scores
        XCTAssertEqual(JamJudge.decide(S(speech: 0.1, music: 0.4, drums: 0.4, pitched: 0.05)), .beatbox)
        XCTAssertEqual(JamJudge.decide(S(speech: 0.1, music: 0.6, drums: 0.3, pitched: 0.6)), .playing, "a band with drums is playing")
    }
}

final class MumbleAndChordRowTests: XCTestCase {
    func testVoicedGapKeepsTheSentenceOneLine() {
        let w = [TimedWord(text: "no", start: 0, end: 0.3), TimedWord(text: "I'm", start: 0.3, end: 0.5),
                 TimedWord(text: "gonna", start: 3.9, end: 4.2), TimedWord(text: "shoot", start: 4.2, end: 4.5)]
        XCTAssertEqual(LyricArranger.lines(words: w).count, 2, "silence between: two lines")
        XCTAssertEqual(LyricArranger.lines(words: w, voiced: { _, _ in true }).count, 1, "mumbling between: one line")
        let long = (0..<6).map { TimedWord(text: "w\($0)", start: Double($0) * 2, end: Double($0) * 2 + 0.3) }
        XCTAssertEqual(LyricArranger.lines(words: long, voiced: { _, _ in true }).count, 2, "lines still end at maxSpan")
    }

    func testIntroChordsGetARow() throws {
        let json = """
        {"id":"t","createdAt":"2026-10-13T20:59:09Z","daw":"Jam","durationSeconds":49,"sessionStartSeconds":0,"confidence":0,
         "kind":"playing","files":{},"route":"speakers","notes":0,"padding":0,"chords":[{"name":"Eb","start":0,"end":4},{"name":"Gm","start":4,"end":7},
         {"name":"Ab","start":7,"end":20},{"name":"Eb","start":20,"end":40}]}
        """
        let take = try LyricSheet.decoder.decode(TakeRecord.self, from: Data(json.utf8))
        let rows = LabSessionExport.chordRows([take], around: [(26, 31)])
        XCTAssertEqual(rows.first?.first?.text, "chords · Eb Gm Ab", "a chord running under the sung line is left out")
        XCTAssertEqual(rows.count, 1, "chords under the sung line are left out")
    }
}
