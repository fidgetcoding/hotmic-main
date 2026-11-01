import XCTest
@testable import Library
import Enrichment
import Timeline

final class NotebookTests: XCTestCase {
    /// A take whose lyrics are `lines`, words 0.3 s apart, a 1 s breath between lines.
    static func take(_ id: String, at seconds: Double, _ lines: [String], position: MusicalPosition? = nil, padding: Double = 0) -> TakeRecord {
        var words: [Lyrics.Word] = []
        var t = padding
        for line in lines {
            for w in line.split(separator: " ") { words.append(.init(text: String(w), start: t, end: t + 0.25)); t += 0.3 }
            t += 1
        }
        var r = TakeRecord(id: id, createdAt: Date(timeIntervalSince1970: seconds), daw: "Jam", sessionStartSeconds: seconds,
                           durationSeconds: t, confidence: 1, route: "mic", files: [:], position: position)
        r.lyrics = Lyrics(text: lines.joined(separator: " "), words: words)
        r.padding = padding
        return r
    }

    let passes = [
        take("t1", at: 0, ["paper moon over the river tonight", "I keep your letters in a coat", "the city hums a borrowed song"]),
        take("t2", at: 60, ["paper moon over the river tonight", "I kept your letters in my coat", "the city hums a borrowed song",
                            "and I'm still walking home alone"]),
        take("t3", at: 120, ["paper moon down by the water", "burning all your letters now", "the city hums a borrowed song"]),
    ]

    func testPassesLineUpLineByLine() {
        let book = Notebook(takes: passes)
        XCTAssertEqual(book.slots.map { $0.versions.count }, [3, 3, 3, 1], book.slots.map { $0.versions.map(\.text) }.description)
        XCTAssertEqual(book.slots[1].versions.map(\.text),
                       ["I keep your letters in a coat", "I kept your letters in my coat", "burning all your letters now"],
                       "a rewritten line between two matching lines is a version of that line")
        XCTAssertEqual(book.slots[3].versions[0].text, "and I'm still walking home alone", "a new line stays a new line")
    }

    func testDraftUsesKeepersElseNewest() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hm-nb-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NotebookStore(folder: folder)
        var book = Notebook(takes: passes, keepers: store.keepers())
        XCTAssertEqual(book.draft.components(separatedBy: "\n")[0], "paper moon down by the water")
        try store.pick("t1#0", in: book.slots[0])
        try store.pick("t2#1", in: book.slots[1])
        book = Notebook(takes: passes, keepers: store.keepers())
        XCTAssertEqual(book.draft, """
            paper moon over the river tonight
            I kept your letters in my coat
            the city hums a borrowed song
            and I'm still walking home alone
            """)
        try store.pick("t2#1", in: book.slots[1])            // tap again = un-pick
        XCTAssertEqual(Notebook(takes: passes, keepers: store.keepers()).slots[1].chosen.id, "t3#1")
        XCTAssertTrue(try String(contentsOf: store.writeDraft(book, title: "Paper Moon")).contains("# Paper Moon"))
    }

    func testDiffMarksTheWordsYouChanged() {
        let d = Notebook.diff("I kept your letters in my coat", against: "I keep your letters in a coat")
        XCTAssertEqual(d.filter(\.changed).map(\.word), ["kept", "my"])
    }

    func testBreathsSplitLines() {
        XCTAssertEqual(Notebook.lines(of: passes[1]).map(\.text).count, 4)
        XCTAssertEqual(Notebook.lines(of: passes[1])[1].start, 0 + 6 * 0.3 + 1, accuracy: 0.001)
    }

    /// In a DAW: a line sung at a different part of the song is never mistaken for a rewrite.
    func testBarsKeepDifferentPartsApart() {
        func at(_ bar: Int) -> MusicalPosition { MusicalPosition(bar: bar, beat: 1, sixteenth: 1, tempo: 120, beatsPerBar: 4, playing: true) }
        let verse = Self.take("v", at: 0, ["paper moon over the river tonight", "I keep your letters in a coat"], position: at(9), padding: 1.5)
        let later = Self.take("c", at: 60, ["paper moon over the river tonight", "the chorus hits a different line"], position: at(9), padding: 1.5)
        let chorus = Self.take("x", at: 90, ["totally new words for the bridge"], position: at(41), padding: 1.5)
        let book = Notebook(takes: [verse, later, chorus])
        XCTAssertEqual(book.slots.map { $0.versions.count }, [2, 2, 1], book.slots.map { $0.versions.map(\.text) }.description)
        XCTAssertEqual(Notebook.lines(of: chorus)[0].bar ?? 0, 41, accuracy: 0.01, "stamped at the first sung word")
    }

    func testSameSessionRepeatsAreVersionsNotEchoes() {
        let index = LyricIndex([.init(id: "t1", title: "this session", text: "paper moon over the river tonight"),
                                .init(id: "old", title: "Old Song", text: "the city hums a borrowed song")])
        let echoes = index.echoes(of: "paper moon over the river tonight. the city hums a borrowed song", excluding: ["t1", "t2"])
        XCTAssertEqual(echoes.map(\.title), ["Old Song"])
    }
}
