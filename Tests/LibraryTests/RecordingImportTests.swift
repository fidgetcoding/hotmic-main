import AVFoundation
import XCTest
@testable import Library

final class RecordingImportTests: XCTestCase {
    /// A voice memo with two sung ideas 10 s apart (longer than a jam's 6 s pause) becomes a session
    /// with two takes, plus the whole recording so it plays back end to end.
    func testDroppedRecordingSplitsIntoTakes() async throws {
        let rate = 44_100.0
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hm-import-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let memo = dir.appendingPathComponent("New Recording 12.m4a")
        let folder = dir.appendingPathComponent("session")

        var samples = (0..<Int(22 * rate)).map { _ in Float.random(in: -0.0003...0.0003) }
        let sung = TakePipelineTests().sung(3, rate: rate)
        for start in [2.0, 15.0] { for i in sung.indices { samples[Int(start * rate) + i] += sung[i] } }
        try write(samples, rate: rate, to: memo)

        var last = 0.0
        let takes = try await RecordingImport.run(url: memo, folder: folder, progress: { last = $0 })

        XCTAssertEqual(last, 1, accuracy: 0.001)
        XCTAssertEqual(takes.count, 2, "two ideas 10 s apart are two takes")
        XCTAssertEqual(takes.first?.sessionStartSeconds ?? -1, 0.5, accuracy: 0.3)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertTrue(files.contains("session__voice_001.m4a"))
        XCTAssertTrue(files.contains("session__mix_001.m4a"))
        let whole = try AVAudioFile(forReading: folder.appendingPathComponent("session__voice_001.m4a"))
        XCTAssertEqual(Double(whole.length) / whole.processingFormat.sampleRate, 22, accuracy: 0.2)
        XCTAssertTrue(RecordingImport.accepts(memo))
        XCTAssertFalse(RecordingImport.accepts(dir.appendingPathComponent("lyrics.txt")))
    }

    private func write(_ samples: [Float], rate: Double, to url: URL) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for i in samples.indices { buffer.floatChannelData![0][i] = samples[i] }
        try file.write(from: buffer)
    }
}
