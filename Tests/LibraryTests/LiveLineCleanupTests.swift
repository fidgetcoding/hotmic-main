import XCTest
@testable import Detection
import Enrichment
@testable import Library

/// Nate's 2026-10-13 late test (session "233010 Jam", hotmic.log 03:30–03:40Z).
final class LiveLineCleanupTests: XCTestCase {
    func testFixDropsTheNextLinesStart() {
        let t = LiveLineCleanup.trim("as soon as you start saying stuff, it's gonna start registering what you're saying, then if there's an obvious,",
                                     previous: nil, next: "there's an obvious break it's gonna make the lime break so like if I'm you know")
        XCTAssertEqual(t, "as soon as you start saying stuff, it's gonna start registering what you're saying, then if")
    }

    func testFixDropsAWordCutShortAtTheClipEnd() {
        let t = LiveLineCleanup.trim("then everything that comes after that will go into whatever the next section is and then i could easily blow",
                                     previous: nil, next: "I could easily block these up and you know split them")
        XCTAssertEqual(t, "then everything that comes after that will go into whatever the next section is and then")
    }

    func testFixDropsThePreviousLinesTail() {
        let t = LiveLineCleanup.trim("it up it should eventually see it", previous: "obvious break so like if you know it so as it up", next: nil)
        XCTAssertEqual(t, "it should eventually see it")
    }

    func testWhisperSayingAPhraseTwice() {
        let t = LiveLineCleanup.trim("I can easily block these up and, you know, split them as I need to  and you know, split them as I need to",
                                     previous: nil, next: nil)
        XCTAssertEqual(t, "I can easily block these up and, you know, split them as I need to")
    }

    func testSameWordsCommittedTwiceKeepOne() {
        let out = LiveLineCleanup.clean([LiveLine(text: "as soon", at: 22.7, end: 23.0, fixed: "as soon as you start"),
                                         LiveLine(text: "as", at: 22.7, end: 23.0)])
        XCTAssertEqual(out.map(\.text), ["as soon"])
    }

    func testShortLineThePreviousFixAlreadyEndsWith() {
        let out = LiveLineCleanup.clean([LiveLine(text: "see a comment", at: 48.8, end: 53.2, fixed: "and so it'll be mapped to the beat. There's a loop mode"),
                                         LiveLine(text: "loop", at: 53.4, end: 53.7)])
        XCTAssertEqual(out.count, 1)
    }

    func testFillerOnlyIsNotAVersion() {
        XCTAssertFalse(LabSessionExport.sameLine("where, um", "fireman, um"))
        XCTAssertTrue(LabSessionExport.sameLine("it's gonna start registering what you're saying",
                                                "saying stuff it's gonna start registering what you're saying then if there's an obvious there's an"))
    }

    func testJamTalkAndBeatBleedAreNotPlaying() {
        typealias S = AppleVoiceJudge.Scores
        XCTAssertEqual(JamJudge.decide(S(rapping: 0.4, speech: 0.3, music: 0.6, instrument: 0.7), beat: true), .rap, "beat bleed under rap")
        XCTAssertNotEqual(JamJudge.decide(S(singing: 0.35, speech: 0.1, music: 0.5)), .playing, "a voice with no instrument")
    }

    func testSungLinesShowTheirNotesRapLinesDont() {
        func take(_ kind: String, at: Double) -> TakeRecord {
            var r = TakeRecord(id: kind, createdAt: Date(), daw: "Jam", sessionStartSeconds: at, durationSeconds: 4,
                               confidence: 1, route: "mic", files: [:], position: nil)
            r.kind = kind
            r.midiNotes = [Note(pitch: 57, sungPitch: 57, start: 0.5, duration: 0.4, velocity: 90),
                           Note(pitch: 60, sungPitch: 60, start: 1.2, duration: 0.4, velocity: 90)]
            return r
        }
        func line(_ at: Double) -> [LabSession.Version] {
            [LabSession.Version(id: "l\(at)", takeID: "", text: "fly away tonight", start: 0, end: 3, at: at, words: [], chords: [], keeper: false)]
        }
        let out = LabSessionExport.sungNotes([take("singing", at: 0), take("rap", at: 10)], [line(0), line(10)])
        XCTAssertEqual(out[0][0].notes, ["A3", "C4"])
        XCTAssertEqual(out[1][0].notes, [])
    }

    func testPastedVerseBecomesRowsInOrder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hm-typed-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        LiveLines.append(LiveLine(text: "sung first", at: 1, end: 3), to: folder)
        LiveLines.type("wrote this on the train\n\nand this one too\n", at: 4, to: folder)
        let rows = LyricArranger.arrange(takes: [], keepers: [], live: LiveLines.read(folder)).map { $0.map(\.text) }
        XCTAssertEqual(rows, [["sung first"], ["wrote this on the train"], ["and this one too"]])
    }

    /// Session 233010: the retake cut its lines in different places; every re-sung line still pairs.
    func testRetakeWithDifferentBreaksPairsLineForLine() {
        let live = [LiveLine(text: "as soon as you start saying stuff", at: 1, end: 3),
                    LiveLine(text: "it's gonna start registering what you're saying", at: 3.5, end: 5),
                    LiveLine(text: "then if there's an obvious break it's gonna make the line break", at: 6, end: 10),
                    LiveLine(text: "you see it reformatting itself", at: 12, end: 15),
                    LiveLine(text: "as soon as you start saying stuff it's gonna start registering what you're saying then if there's an obvious", at: 22, end: 28),
                    LiveLine(text: "break it's gonna make the line break", at: 28.5, end: 31)]
        let rows = LyricArranger.arrange(takes: [], keepers: [], live: live)
        XCTAssertEqual(rows.count, 4, "\(rows.map { $0.map(\.text) })")
        XCTAssertEqual(rows.prefix(3).map(\.count), [2, 2, 2], "\(rows.map { $0.map(\.text) })")
    }

    func testDeletedStretchHidesItsLinesAndUndoBringsThemBack() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hm-hide-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        LiveLines.append(LiveLine(text: "keep this hook", at: 1, end: 3), to: folder)
        LiveLines.append(LiveLine(text: "whack verse here", at: 10, end: 13), to: folder)
        HiddenRanges.hide(HiddenRange(a: 9, b: 14), in: folder)
        XCTAssertEqual(LabSessionExport.session(folder: folder).slots.map { $0.map(\.text) }, [["keep this hook"]])
        HiddenRanges.unhideLast(in: folder)
        XCTAssertEqual(LabSessionExport.session(folder: folder).slots.count, 2)
    }
}
