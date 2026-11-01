import XCTest
@testable import Library
import Enrichment
import Timeline

final class MIDISlicesTests: XCTestCase {
    /// Two sung lines at 120 BPM (2 s per bar), first word on bar 9 beat 1 after 1.5 s of padding.
    func take() -> TakeRecord {
        var t = NotebookTests.take("t", at: 0, ["paper moon over the river", "I keep your letters here"],
                                   position: MusicalPosition(bar: 9, beat: 1, sixteenth: 1, tempo: 120, beatsPerBar: 4, playing: true),
                                   padding: 1.5)
        // One note per word, starting with the word.
        t.midiNotes = t.lyrics!.words.enumerated().map { i, w in
            Note(pitch: 60 + i, sungPitch: Double(60 + i), start: w.start, duration: 0.25, velocity: 90)
        }
        return t
    }

    func testOneClipPerLineStartingOnItsBar() throws {
        let t = take()
        let lines = MIDISlices.lines(for: t)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].name.hasPrefix("line-01 paper moon over the"), lines[0].name)
        XCTAssertEqual(lines[0].anchor, 1.5, accuracy: 1e-9, "line 1 starts on bar 9's downbeat")
        // Line 2 starts at 1.5 + 5×0.3 + 1 = 4.0 s → bar 10 (downbeat 3.5 s).
        XCTAssertEqual(lines[1].anchor, 3.5, accuracy: 1e-9)
        let first = try XCTUnwrap(MIDISlices.data(lines[0], take: t))
        let second = try XCTUnwrap(MIDISlices.data(lines[1], take: t))
        XCTAssertEqual(noteOns(first), [60, 61, 62, 63, 64])
        XCTAssertEqual(noteOns(second), [65, 66, 67, 68, 69])
    }

    func testFourBarPhrasesUseRealBarNumbers() {
        let names = MIDISlices.phrases(for: take()).map(\.name)
        XCTAssertEqual(names, ["bars 009-012"])
    }

    func testJamTakeUsesDetectedTempoWithTheFirstNoteOnTheDownbeat() throws {
        var t = take()
        t.position = nil
        t.tempo = TempoEstimator.Result(bpm: 100, confidence: 0.8)
        let grid = try XCTUnwrap(MIDISlices.grid(for: t))
        XCTAssertEqual(grid.firstDownbeat, 1.5, accuracy: 1e-9)
        XCTAssertEqual(grid.secondsPerBar, 2.4, accuracy: 1e-9)
        XCTAssertEqual(MIDISlices.phrases(for: t).map(\.name), ["bars 001-004"])
    }

    func testWritesAFolderOfClips() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hm-midi-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let out = try MIDISlices.write(take(), in: folder)
        let files = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
        XCTAssertEqual(files.count, 3, files.description)   // 2 lines + 1 phrase
    }

    /// Note numbers of every note-on in a format-0 file (running status not used by our writer).
    func noteOns(_ data: Data) -> [Int] {
        let b = [UInt8](data)
        var out: [Int] = []
        var i = 22                                            // MThd(14) + "MTrk" + length
        while i < b.count - 2 {
            while b[i] & 0x80 != 0 { i += 1 }                // delta-time VLQ
            i += 1
            let status = b[i]
            if status == 0xFF { let len = Int(b[i + 2]); i += 3 + len; continue }
            if status & 0xF0 == 0x90 { out.append(Int(b[i + 1])) }
            i += 3
        }
        return out
    }
}
