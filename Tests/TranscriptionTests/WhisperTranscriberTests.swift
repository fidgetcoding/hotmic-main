import AVFoundation
import XCTest
@testable import Transcription

/// Real WhisperKit end to end. Downloads a model once (~75 MB for tiny.en), so it's opt-in:
/// HM_WHISPER=1 swift test --filter WhisperTranscriberTests
final class WhisperTranscriberTests: XCTestCase {
    func testResampleKeepsDuration() throws {
        let x = [Float](repeating: 0.1, count: 48_000)
        XCTAssertEqual(Double(try WhisperTranscriber.resample(x, from: 48_000, to: 16_000).count), 16_000, accuracy: 64)
    }

    func testTheModelGoesInApplicationSupportUnlessACopyIsAlreadyInDocuments() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertEqual(WhisperTranscriber.modelFolder(home: home).path, home.appendingPathComponent("Library/Application Support/Hot Mic/Models").path, "a clean Mac")
        let existing = home.appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-\(WhisperTranscriber.defaultModel)")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        XCTAssertEqual(WhisperTranscriber.modelFolder(home: home).path, home.appendingPathComponent("Documents/huggingface").path, "no second 1.5 GB download")
    }

    func testTranscribesSpokenWords() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HM_WHISPER"] == "1", "set HM_WHISPER=1 (downloads a model)")
        let aiff = FileManager.default.temporaryDirectory.appendingPathComponent("hm-say-\(UUID()).aiff")
        defer { try? FileManager.default.removeItem(at: aiff) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", aiff.path, "paper moon over the river tonight"]
        try say.run(); say.waitUntilExit()

        let file = try AVAudioFile(forReading: aiff)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))

        let model = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/hotmic-test-models")
        let lyrics = try await WhisperTranscriber(model: "tiny.en", downloadBase: model)
            .transcribe(samples, sampleRate: file.processingFormat.sampleRate)
        print("HM_WHISPER text:", lyrics.text, "words:", lyrics.words.count)
        XCTAssertTrue(lyrics.text.lowercased().contains("moon"), lyrics.text)
        XCTAssertFalse(lyrics.words.isEmpty)
    }
}

/// Whispered and quiet lines: macOS's "Whisper" voice, played back ~40 dB down.
final class WhisperedLineTests: XCTestCase {
    static func whispered(_ text: String, peakDB: Float) throws -> (samples: [Float], rate: Double) {
        let aiff = FileManager.default.temporaryDirectory.appendingPathComponent("hm-whisper-\(UUID()).aiff")
        defer { try? FileManager.default.removeItem(at: aiff) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Whisper", "-o", aiff.path, text]
        try say.run(); say.waitUntilExit()
        let file = try AVAudioFile(forReading: aiff)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        var samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let peak = samples.map(abs).max() ?? 1
        let gain = powf(10, peakDB / 20) / max(peak, 1e-6)
        samples = samples.map { $0 * gain }
        return (samples, file.processingFormat.sampleRate)
    }

    func testTranscribesAQuietWhisperWithTheAppModel() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HM_WHISPER"] == "1", "set HM_WHISPER=1 (uses the app's model)")
        let (samples, rate) = try Self.whispered("I keep your letters in a coat by the door", peakDB: -40)
        let lyrics = try await WhisperTranscriber().transcribe(samples, sampleRate: rate, hint: "paper moon over the river tonight")
        print("HM_WHISPER whisper text:", lyrics.text)
        let got = Set(lyrics.text.lowercased().split { !$0.isLetter }.map(String.init))
        XCTAssertGreaterThanOrEqual(got.intersection(["keep", "letters", "coat", "door"]).count, 3, lyrics.text)
    }
}
