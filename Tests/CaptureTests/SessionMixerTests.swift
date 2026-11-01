import XCTest
@testable import Capture

final class RecordingSink: AudioFileSink {
    let channels: Int
    var samples: [Float] = []
    var finished = false
    init(channels: Int) { self.channels = channels }
    func append(interleaved: UnsafeBufferPointer<Float>, frames: Int) throws { samples += interleaved.prefix(frames * channels) }
    func finish() throws { finished = true }
}

struct Halve: VoiceProcessing {
    var latencyFrames: Int { 0 }
    func process(mic: UnsafeMutableBufferPointer<Float>, reference: UnsafeBufferPointer<Float>, frames: Int) {
        for i in 0..<frames { mic[i] *= 0.5 }
    }
}

final class SessionMixerTests: XCTestCase {
    func testVoiceIsProcessedMicAndMixAddsVoiceToBothSessionChannels() throws {
        let voice = RecordingSink(channels: 1), mix = RecordingSink(channels: 2)
        let mixer = SessionMixer(voiceSink: voice, mixSink: mix, processor: Halve())
        var mic: [Float] = [0.4, 0.2]
        let session: [Float] = [0.1, -0.1, 0.3, -0.3]  // L R L R
        try mixer.consume(mic: &mic, session: session, frames: 2)
        XCTAssertEqual(voice.samples, [0.2, 0.1])
        XCTAssertEqual(mix.samples, [0.3, 0.1, 0.4, -0.2].map { Float($0) }, accuracy: 1e-6)
    }

    func testPassthroughByDefault() throws {
        let voice = RecordingSink(channels: 1), mix = RecordingSink(channels: 2)
        let mixer = SessionMixer(voiceSink: voice, mixSink: mix)
        var mic: [Float] = [0.5]
        try mixer.consume(mic: &mic, session: [0, 0], frames: 1)
        XCTAssertEqual(voice.samples, [0.5])
    }

    func testMixDelaysSessionToMatchProcessorLatency() throws {
        struct OneFrameLate: VoiceProcessing {
            var latencyFrames: Int { 1 }
            func process(mic: UnsafeMutableBufferPointer<Float>, reference: UnsafeBufferPointer<Float>, frames: Int) {}
        }
        let voice = RecordingSink(channels: 1), mix = RecordingSink(channels: 2)
        let mixer = SessionMixer(voiceSink: voice, mixSink: mix, processor: OneFrameLate())
        var mic: [Float] = [0, 0]
        try mixer.consume(mic: &mic, session: [0.1, 0.2, 0.3, 0.4], frames: 2)
        XCTAssertEqual(mix.samples, [0, 0, 0.1, 0.2], "session shifted by one frame")
    }

    func testFinishClosesBothSinks() throws {
        let voice = RecordingSink(channels: 1), mix = RecordingSink(channels: 2)
        try SessionMixer(voiceSink: voice, mixSink: mix).finish()
        XCTAssertTrue(voice.finished && mix.finished)
    }
}

func XCTAssertEqual(_ a: [Float], _ b: [Float], accuracy: Float, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line) }
}

final class FailingSink: AudioFileSink {
    let channels: Int
    init(channels: Int) { self.channels = channels }
    struct Boom: Error {}
    func append(interleaved: UnsafeBufferPointer<Float>, frames: Int) throws { throw Boom() }
    func finish() throws {}
}

final class MixerFailureTests: XCTestCase {
    func testFailedVoiceWriteKeepsMixAndTimelineInStep() {
        let mix = RecordingSink(channels: 2)
        let mixer = SessionMixer(voiceSink: FailingSink(channels: 1), mixSink: mix)
        var seen = 0
        mixer.onMixed = { _, _, frames, _ in seen += frames }
        var mic: [Float] = [0.1, 0.2]
        XCTAssertThrowsError(try mixer.consume(mic: &mic, session: [0, 0, 0, 0], frames: 2))
        XCTAssertEqual(mix.samples.count, 4, "mix still written")
        XCTAssertEqual(seen, 2, "takes still see the audio")
        XCTAssertEqual(mixer.position, 2, "timeline still advances")
    }
}
