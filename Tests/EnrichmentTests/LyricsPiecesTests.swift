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
