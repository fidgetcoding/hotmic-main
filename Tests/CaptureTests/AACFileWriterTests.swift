import AVFoundation
import XCTest
@testable import Capture

final class AACFileWriterTests: XCTestCase {
    func testWritesReadableStereoAAC() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hm-test-\(UUID()).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AACFileWriter(url: url, sampleRate: 48_000, channels: 2, bitRate: 192_000)
        var tone = [Float](repeating: 0, count: 48_000 * 2)
        for i in 0..<48_000 { let s = 0.3 * sin(Float(i) * 2 * .pi * 440 / 48_000); tone[2 * i] = s; tone[2 * i + 1] = s }
        for start in stride(from: 0, to: 48_000, by: 4_800) {  // 10 chunks
            try tone.withUnsafeBufferPointer { try writer.append(interleaved: UnsafeBufferPointer(rebasing: $0[(start * 2)...]), frames: 4_800) }
        }
        try writer.finish()

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
        XCTAssertEqual(file.fileFormat.sampleRate, 48_000)
        XCTAssertEqual(Double(file.length), 48_000, accuracy: 2_048, "about one second after AAC priming")
    }
}

final class HighSampleRateWriterTests: XCTestCase {
    func testNinetySixKilohertzSessionsStillRecord() throws {
        for rate in [88_200.0, 96_000, 192_000] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("hm-hr-\(UUID()).m4a")
            defer { try? FileManager.default.removeItem(at: url) }
            let writer = try AACFileWriter(url: url, sampleRate: rate, channels: 1, bitRate: 96_000)
            let second = Int(rate)
            let tone = (0..<second).map { Float(0.3 * sin(Double($0) * 2 * .pi * 440 / rate)) }
            for start in stride(from: 0, to: second, by: 4_800) {
                let n = min(4_800, second - start)
                try tone.withUnsafeBufferPointer { try writer.append(interleaved: UnsafeBufferPointer(rebasing: $0[start..<(start + n)]), frames: n) }
            }
            try writer.finish()
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(file.fileFormat.sampleRate, 48_000, "\(rate)")
            XCTAssertEqual(Double(file.length), 48_000, accuracy: 3_000, "about one second at \(rate)")
        }
    }
}

final class SegmentedWriterTests: XCTestCase {
    func testRollsIntoClosedSegments() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hm-seg-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let w = try SegmentedAACWriter(folder: folder, baseName: "session__voice", sampleRate: 48_000, channels: 1,
                                       bitRate: 96_000, segmentSeconds: 1)
        let audio = [Float](repeating: 0.1, count: 48_000 * 5 / 2)       // 2.5 s → 3 segments
        try audio.withUnsafeBufferPointer { try w.append(interleaved: $0, frames: audio.count) }
        // Before finish, the first two segments are already closed and playable (crash safety).
        XCTAssertEqual(try AVAudioFile(forReading: w.segments[0]).length, 48_000, accuracy: 2_048)
        XCTAssertEqual(try AVAudioFile(forReading: w.segments[1]).length, 48_000, accuracy: 2_048)
        try w.finish()
        XCTAssertEqual(w.segments.map(\.lastPathComponent), ["session__voice_001.m4a", "session__voice_002.m4a", "session__voice_003.m4a"])
    }
}

private func XCTAssertEqual(_ a: Int64, _ b: Int64, accuracy: Int64, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThanOrEqual(abs(a - b), accuracy, "\(a) vs \(b)", file: file, line: line)
}
