import XCTest
@testable import Enrichment
@testable import Library
import Capture

final class LyricIndexTests: XCTestCase {
    let catalog = [
        LyricIndex.Document(id: "s1", title: "Neon Rivers", text: "paper moon over the river tonight\nwe were running out of time"),
        LyricIndex.Document(id: "s2", title: "Glass Hours", text: "running out of time again\nneon lights on the highway"),
        LyricIndex.Document(id: "s3", title: "Late Train", text: "i keep running out of time\nthe last train home"),
    ]

    func testRecognizesALineYouAlreadyWroteDespiteSmallChanges() {
        let echoes = LyricIndex(catalog).echoes(of: "Paper moon over the river, tonight. Something new here now")
        XCTAssertEqual(echoes.count, 1)
        XCTAssertEqual(echoes.first?.title, "Neon Rivers")
        XCTAssertEqual(echoes.first?.matchedLine, "paper moon over the river tonight")
    }

    func testIgnoresItselfWhenExcluded() {
        XCTAssertTrue(LyricIndex(catalog).echoes(of: "the last train home tonight", excluding: "s3").isEmpty)
    }

    func testFlagsPhrasesReusedAcrossSongs() {
        let phrases = LyricIndex(catalog).repeatedPhrases(minSongs: 3)
        XCTAssertEqual(phrases.first?.text, "running out of time")
        XCTAssertEqual(phrases.first?.songs, 3)
    }
}

final class LibraryIndexTests: XCTestCase {
    func testReadsSessionsTakesAndImportsIntoOneLyricMemory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hm-lib-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let index = LibraryIndex(location: LibraryLocation(root: root))
        let session = index.location.sessions.appendingPathComponent("2026-09-27 2100 Ableton Live")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let take = TakeRecord(id: "t1", createdAt: Date(), daw: "Ableton Live", sessionStartSeconds: 12, durationSeconds: 8,
                              confidence: 0.9, route: "headphones", files: [:], lyrics: Lyrics(text: "paper moon over the river", words: []))
        try LyricSheet.encoder.encode(take).write(to: session.appendingPathComponent("t1.json"))
        try index.save(ImportedSong(title: "Old Song", lyrics: "we were running out of time"))

        XCTAssertEqual(index.sessions().map(\.daw), ["Ableton Live"])
        XCTAssertEqual(index.sessions().first?.takes.map(\.id), ["t1"])
        XCTAssertEqual(index.imports().map(\.title), ["Old Song"])
        XCTAssertEqual(Set(index.lyricDocuments().map(\.text)), ["paper moon over the river", "we were running out of time"])
    }
}

final class SongImporterTests: XCTestCase {
    func testImportsAudioWithLyricsAndKeyAndPastedLyrics() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hm-import-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // A "finished song": C major chords, written as AAC.
        let url = root.appendingPathComponent("Old Demo.m4a")
        let writer = try Capture.AACFileWriter(url: url, sampleRate: 48_000, channels: 2, bitRate: 192_000)
        let chords: [[Double]] = [[60, 64, 67], [65, 69, 72], [67, 71, 74], [60, 64, 67]]
        var audio: [Float] = []
        for chord in chords {
            for i in 0..<72_000 {
                let t = Double(i) / 48_000
                let s = Float(chord.reduce(0.0) { $0 + 0.08 * sin(2 * .pi * 440 * pow(2, ($1 - 69) / 12) * t) })
                audio += [s, s]
            }
        }
        try audio.withUnsafeBufferPointer { try writer.append(interleaved: $0, frames: audio.count / 2) }
        try writer.finish()

        let importer = SongImporter(index: LibraryIndex(location: LibraryLocation(root: root)), transcriber: StubTranscriber())
        let song = try await importer.importAudio(url)
        XCTAssertEqual(song.title, "Old Demo")
        XCTAssertEqual(song.key?.short, "Cmaj")
        XCTAssertTrue(song.lyrics.contains("paper moon"))

        try importer.importLyrics(title: "Notes app verse", text: "  written on the train  ")
        XCTAssertEqual(Set(importer.index.imports().map(\.title)), ["Old Demo", "Notes app verse"])
        XCTAssertTrue(importer.index.imports().contains { $0.lyrics == "written on the train" })
    }
}
