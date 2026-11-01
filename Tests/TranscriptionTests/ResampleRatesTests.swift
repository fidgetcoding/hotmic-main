import XCTest
@testable import Transcription

final class ResampleRatesTests: XCTestCase {
    /// Every capture rate Hot Mic sees comes out at 16 kHz with its full length (bench 2026-10-28:
    /// 48 kHz takes under ~25 s came back with no words).
    func testEveryRateKeepsItsLength() throws {
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            for seconds in [4.0, 22.0, 60.0] {
                let n = Int(rate * seconds)
                let x = (0..<n).map { Float(0.3 * sin(2 * .pi * 220 * Double($0) / rate)) }
                let y = try WhisperTranscriber.resample(x, from: rate, to: 16_000)
                XCTAssertEqual(Double(y.count) / 16_000, seconds, accuracy: 0.05, "\(rate) Hz, \(seconds) s → \(y.count) samples")
            }
        }
    }
}
