import XCTest
@testable import Enrichment

final class LyricsPiecesTests: XCTestCase {
    func testLoopsAreOneWordOverAndOver() {
        XCTAssertTrue(Lyrics.isLoop("man, man, man, man, man"))
        XCTAssertTrue(Lyrics.isLoop("man, you, man, man, man"))
        XCTAssertFalse(Lyrics.isLoop("yeah, yeah, yeah"))                                   // too short to call
        XCTAssertFalse(Lyrics.isLoop("don't lie, i know you don't like teasing but you touch it"))
        XCTAssertFalse(Lyrics.isLoop("B-L-U double R-E-D we touching"))
    }

    func testShortAudioIsOnePiece() {
        XCTAssertEqual(Lyrics.pieces([Float](repeating: 0.1, count: 16_000 * 20), sampleRate: 16_000), [0..<(16_000 * 20)])
    }

    func testLongAudioCutsAtTheQuietSpot() {
        let rate = 16_000.0
        // 60 s of signal with one quiet half-second at 21 s: the first cut lands there, every piece ≤ 25 s.
        var x = [Float](repeating: 0.3, count: Int(rate * 60))
        for i in Int(rate * 21)..<Int(rate * 21.5) { x[i] = 0 }
        let p = Lyrics.pieces(x, sampleRate: rate)
        XCTAssertEqual(Double(p[0].upperBound) / rate, 21.25, accuracy: 0.3)
        XCTAssertTrue(p.allSatisfy { Double($0.count) / rate <= 25.01 })
        XCTAssertEqual(p.first?.lowerBound, 0)
        XCTAssertEqual(p.last?.upperBound, x.count)
        for (a, b) in zip(p, p.dropFirst()) { XCTAssertEqual(a.upperBound, b.lowerBound) }
    }
}

final class LyricsRepairTests: XCTestCase {
    private func words(_ pairs: [(String, Double, Double)]) -> [Lyrics.Word] { pairs.map { Lyrics.Word(text: $0.0, start: $0.1, end: $0.2) } }

    func testLoopsComeOutAndTheRealWordsStay() {
        let text = "drop it on the freeway whoa whoa whoa whoa whoa whoa whoa diamonds on my wrist".split(separator: " ").map(String.init)
        let keep = Lyrics.withoutLoops(text).map { text[$0] }
        XCTAssertEqual(keep.joined(separator: " "), "drop it on the freeway whoa whoa whoa diamonds on my wrist")
    }

    func testAPhraseLoopKeepsTwo() {
        let text = (["hold", "up,"] + (0..<20).flatMap { _ in ["hold", "up,"] } + ["next", "line"])
        XCTAssertEqual(Lyrics.withoutLoops(text).map { text[$0] }, ["hold", "up,", "hold", "up,", "next", "line"])
    }

    func testAHookSungAFewTimesIsNotALoop() {
        let text = (0..<4).flatMap { _ in ["whip", "it", "out", "the", "freeway"] }
        XCTAssertEqual(Lyrics.withoutLoops(text).count, text.count)
    }

    func testVoicedSecondsCountsSound() {
        let x = [Float](repeating: 0.1, count: 16_000) + [Float](repeating: 0, count: 16_000)
        XCTAssertEqual(Lyrics.voicedSeconds(x[...], sampleRate: 16_000), 1, accuracy: 0.1)
    }

    func testCollapsedWordsSpreadBetweenTheTimesThatCanBeBelieved() {
        // "c d e f" all stamped at 3.0 between a word ending at 1 and one starting at 5.
        let got = Lyrics.spreadCollapsed(words([("aa", 0.5, 1), ("cc", 3, 3), ("dd", 3, 3), ("ee", 3, 3), ("ff", 3, 3), ("gg", 5, 5.4)]), from: 0, to: 10)
        XCTAssertEqual(got.map(\.text), ["aa", "cc", "dd", "ee", "ff", "gg"], "words and order never change")
        for (a, b) in zip(got, got.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start + 1e-9, "in time order") }
        XCTAssertEqual(got[1].start, 1, accuracy: 0.001, "picks up where the last good word ended")
        XCTAssertGreaterThan(got[4].end, got[1].start + 0.5)
        XCTAssertEqual(got[0].start, 0.5, "good words stay put")
        XCTAssertEqual(got[5].start, 5)
    }

    func testAWordLastingSixSecondsIsNotBelieved() {
        let got = Lyrics.spreadCollapsed(words([("one", 18.7, 24.66), ("two", 24.66, 24.66), ("three", 24.66, 29.12)]), from: 12, to: 30)
        XCTAssertLessThan(got[0].end - got[0].start, 2)
        XCTAssertLessThanOrEqual(got[2].end, 30)
    }

    func testEverythingCollapsedStillSpreads() {
        let got = Lyrics.spreadCollapsed(words((0..<10).map { ("word\($0)", 7, 7) }), from: 5, to: 15)
        XCTAssertGreaterThan(got[9].end, got[0].start + 1)
        XCTAssertEqual(got[0].start, 5, accuracy: 0.001)
        XCTAssertLessThanOrEqual(got[9].end, 15)
    }

    func testGoodTimesAreLeftAlone() {
        let w = words([("aa", 0, 0.3), ("bb", 0.4, 0.7), ("cc", 0.9, 1.2)])
        XCTAssertEqual(Lyrics.spreadCollapsed(w, from: 0, to: 2), w)
    }
}
