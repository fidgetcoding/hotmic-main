import XCTest
@testable import Capture

final class FakeSource: CaptureSource {
    let sampleRate: Double = 48_000
    var mic: RingBuffer?
    var session: RingBuffer?
    var stopped = false
    func start(mic: RingBuffer, session: RingBuffer) throws { self.mic = mic; self.session = session }
    func stop() { stopped = true }
    func push(mic m: [Float], session s: [Float]) { session!.write(s, count: s.count); mic!.write(m, count: m.count) }
}

final class SessionRecorderTests: XCTestCase {
    var source: FakeSource!
    var voice: RecordingSink!
    var mix: RecordingSink!
    var recorder: SessionRecorder!

    override func setUp() {
        source = FakeSource()
        voice = RecordingSink(channels: 1)
        mix = RecordingSink(channels: 2)
        recorder = SessionRecorder(source: source, drainInterval: .seconds(3600)) { [unowned self] _ in
            SessionMixer(voiceSink: voice, mixSink: mix)
        }
    }

    func testDrainsOnlyAlignedFrames() throws {
        try recorder.start()
        source.push(mic: [0.1, 0.2, 0.3], session: [0, 0, 0, 0])  // 3 mic frames, 2 session frames
        recorder.drain()
        XCTAssertEqual(voice.samples, [0.1, 0.2], "never runs ahead of the shorter stream")
        source.session!.write([0, 0], count: 2)
        recorder.drain()
        XCTAssertEqual(voice.samples, [0.1, 0.2, 0.3])
    }

    func testStopFlushesAndFinishes() throws {
        try recorder.start()
        source.push(mic: [0.5], session: [0.1, 0.1])
        try recorder.stop()
        XCTAssertTrue(source.stopped)
        XCTAssertEqual(voice.samples, [0.5])
        XCTAssertTrue(voice.finished && mix.finished)
        XCTAssertFalse(recorder.isRecording)
    }
}

final class SessionRecorderFailureTests: XCTestCase {
    struct Boom: Error {}

    func testFailedMixerSetupStopsTheSource() {
        let source = FakeSource()
        let recorder = SessionRecorder(source: source, drainInterval: .seconds(3600)) { _ in throw Boom() }
        XCTAssertThrowsError(try recorder.start())
        XCTAssertTrue(source.stopped, "mic must not keep running after a failed start")
        XCTAssertFalse(recorder.isRecording)
    }

    func testFilesCloseEvenWhenFinalExportFails() throws {
        let source = FakeSource()
        let voice = RecordingSink(channels: 1), mix = RecordingSink(channels: 2)
        let recorder = SessionRecorder(source: source, drainInterval: .seconds(3600)) { _ in
            let m = SessionMixer(voiceSink: voice, mixSink: mix)
            m.onFinish = { throw Boom() }
            return m
        }
        try recorder.start()
        XCTAssertThrowsError(try recorder.stop())
        XCTAssertTrue(voice.finished && mix.finished)
        XCTAssertFalse(recorder.isRecording)
    }
}

final class HardwareDelayTests: XCTestCase {
    func testMixDelaysSessionByProcessorPlusHardwareLatency() throws {
        let voice = RecordingSink(channels: 1), mix = RecordingSink(channels: 2)
        let mixer = SessionMixer(voiceSink: voice, mixSink: mix, hardwareDelayFrames: 2)
        var mic: [Float] = [0, 0, 0]
        try mixer.consume(mic: &mic, session: [0.1, 0.1, 0.2, 0.2, 0.3, 0.3], frames: 3)
        XCTAssertEqual(mix.samples, [0, 0, 0, 0, 0.1, 0.1])
    }
}
