import XCTest
@testable import Timeline

final class ClockTimelineTests: XCTestCase {
    let tps = 1_000_000.0   // 1 tick = 1 µs for readable tests

    /// Feeds `count` clocks at `bpm` starting at `start` µs; returns time of the last clock.
    @discardableResult
    func clocks(_ t: ClockTimeline, from start: UInt64, count: Int, bpm: Double) -> UInt64 {
        let interval = 60 / bpm / 24 * tps
        var last = start
        for i in 0..<count { last = start + UInt64(Double(i) * interval); t.record(.clock, at: last) }
        return last
    }

    func testStartThenTwoSecondsAt120IsBarTwo() throws {
        let t = ClockTimeline(ticksPerSecond: tps)
        t.record(.start, at: 1_000_000)
        clocks(t, from: 1_000_000, count: 24 * 4 + 1, bpm: 120)   // one bar of 4/4 + the downbeat of bar 2
        let p = try XCTUnwrap(t.position(at: 3_000_000))
        XCTAssertEqual(p.tempo, 120, accuracy: 0.1)
        XCTAssertEqual([p.bar, p.beat, p.sixteenth], [2, 1, 1])
        XCTAssertTrue(p.playing)
    }

    func testSongPositionPointerJumpsBeforeContinue() throws {
        let t = ClockTimeline(ticksPerSecond: tps)
        t.record(.songPosition(sixteenths: 32 + 4), at: 10)          // bar 3, beat 2
        t.record(.continue, at: 20)
        clocks(t, from: 30, count: 1 + 6, bpm: 90)                    // downbeat + one sixteenth
        let p = try XCTUnwrap(t.position(at: 10_000_000))
        XCTAssertEqual([p.bar, p.beat, p.sixteenth], [3, 2, 2])
        XCTAssertEqual(p.tempo, 90, accuracy: 0.1)
    }

    func testStopFreezesPositionAndReportsNotPlaying() throws {
        let t = ClockTimeline(ticksPerSecond: tps)
        t.record(.start, at: 0)
        let last = clocks(t, from: 0, count: 24 * 2 + 1, bpm: 120)
        t.record(.stop, at: last + 1)
        clocks(t, from: last + 20_000, count: 24, bpm: 120)          // DAWs keep sending clock while stopped
        let p = try XCTUnwrap(t.position(at: last + 2_000_000))
        XCTAssertFalse(p.playing)
        XCTAssertEqual([p.bar, p.beat], [1, 3])
    }

    func testThreeFourTimeSignature() throws {
        let t = ClockTimeline(ticksPerSecond: tps)
        t.beatsPerBar = 3
        t.record(.start, at: 0)
        clocks(t, from: 0, count: 24 * 4 + 1, bpm: 100)
        let p = try XCTUnwrap(t.position(at: 10_000_000))
        XCTAssertEqual([p.bar, p.beat], [2, 2])
    }

    func testNoTransportMeansNoPosition() {
        let t = ClockTimeline(ticksPerSecond: tps)
        clocks(t, from: 0, count: 30, bpm: 120)
        XCTAssertNil(t.position(at: 5_000_000))
    }
}

final class FrameClockTests: XCTestCase {
    func testMapsOutputFramesToHostTimeWithLatency() {
        let c = FrameClock(hostAtFrameZero: 1_000_000, sampleRate: 48_000, ticksPerSecond: 1_000_000, latencyFrames: 480)
        XCTAssertEqual(c.host(atOutputFrame: 480), 1_000_000)
        XCTAssertEqual(c.host(atOutputFrame: 48_480), 2_000_000)
    }
}

final class SyncPortDecodeTests: XCTestCase {
    func testDecodesUMPSystemMessages() {
        XCTAssertEqual(SyncPort.decode(0x10F8_0000), .clock)
        XCTAssertEqual(SyncPort.decode(0x10FA_0000), .start)
        XCTAssertEqual(SyncPort.decode(0x10FB_0000), .continue)
        XCTAssertEqual(SyncPort.decode(0x10FC_0000), .stop)
        XCTAssertEqual(SyncPort.decode(0x10F2_2401), .songPosition(sixteenths: 0x24 | 1 << 7))
        XCTAssertNil(SyncPort.decode(0x2090_3C7F), "channel voice (note on) ignored")
    }
}

final class ClockHistoryTests: XCTestCase {
    func testHistoryStaysBoundedAndPositionSurvivesTrimming() throws {
        let tps = 1_000_000.0
        let t = ClockTimeline(ticksPerSecond: tps)
        t.record(.start, at: 0)
        let interval = 60.0 / 120 / 24 * tps           // 120 BPM
        let count = 24 * 2 * 60 * 40                    // 40 minutes of clock
        for i in 0..<count { t.record(.clock, at: UInt64(Double(i) * interval)) }
        XCTAssertLessThan(t.storedEvents, 24 * 2 * 60 * 20, "old history folded away")
        let last = UInt64(Double(count - 1) * interval)
        let p = try XCTUnwrap(t.position(at: last))
        let expectedQuarters = (count - 1) / 24
        XCTAssertEqual(p.bar, expectedQuarters / 4 + 1)
        XCTAssertEqual(p.tempo, 120, accuracy: 0.1)
    }
}
