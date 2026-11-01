import XCTest
@testable import Timeline

/// Bar stamps scored against known truth, on simulated DAW clock streams: every stream is built from a song map,
/// so the true position of every moment is known. Target from the spec: within ±10 ms while the transport runs.
/// Real captures can go through the same scorer: `ClockRecording.parse`, one "seconds status [data…]" per line.
struct ClockRecording {
    var events: [(seconds: Double, event: ClockTimeline.Event)] = []
    /// True position in quarter notes, and tempo, at any moment the song is playing; nil when stopped.
    var truth: (Double) -> (quarters: Double, tempo: Double)?
    var length: Double

    /// A MIDI log: "12.345678 F8", "12.5 F2 10 02" (status and data bytes in hex).
    static func parse(_ text: String) -> [(seconds: Double, event: ClockTimeline.Event)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let p = line.split(separator: " ")
            guard p.count >= 2, let t = Double(p[0]), let status = UInt8(p[1], radix: 16) else { return nil }
            switch status {
            case 0xF8: return (t, .clock)
            case 0xFA: return (t, .start)
            case 0xFB: return (t, .continue)
            case 0xFC: return (t, .stop)
            case 0xF2:
                guard p.count >= 4, let lsb = Int(p[2], radix: 16), let msb = Int(p[3], radix: 16) else { return nil }
                return (t, .songPosition(sixteenths: lsb | msb << 7))
            default: return nil
            }
        }
    }
}

/// Seeded, so a run always sees the same stream.
private struct RNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

private struct Song {
    /// One stretch of playing: where in the song it starts (quarters), when (seconds), its tempo at each moment.
    struct Part { var at: Double; var from: Double; var length: Double; var bpm: (Double) -> Double }
    var parts: [Part]

    /// Builds the MIDI stream a DAW would send for these parts, with the ticks arriving late by `jitter`.
    /// `block`: arrival rounded up to an audio buffer's length, as a clock read off a block-based app would be.
    func recording(jitter: Double = 0, burst: Int = 1, block: Double = 0, idleClocks: Bool = false, seed: UInt64 = 7) -> ClockRecording {
        var rng = RNG(state: seed)
        var out: [(seconds: Double, event: ClockTimeline.Event)] = []
        var ticks: [(t: Double, q: Double, bpm: Double)] = [], ends: [Double] = []
        var previousEnd = 0.0
        for (i, part) in parts.enumerated() {
            // Clocks some DAWs keep sending while stopped.
            if idleClocks {
                var t = previousEnd + 0.02
                while t < part.at - 0.05 { out.append((t, .clock)); t += 60 / 120 / 24 }
            }
            if i > 0 || part.from > 0 { out.append((part.at - 0.002, .songPosition(sixteenths: Int((part.from * 4).rounded())))) }
            out.append((part.at - 0.001, part.from > 0 || i > 0 ? .continue : .start))
            // Ticks: the n-th tick of this part is at the moment the song reaches from + n/24 quarters.
            var t = part.at, n = 0
            var pendingBurst: [Double] = []
            while t < part.at + part.length {
                ticks.append((t, part.from + Double(n) / 24, part.bpm(t - part.at)))
                let late = jitter > 0 ? abs(Double.random(in: -1...1, using: &rng) + Double.random(in: -1...1, using: &rng)) * jitter : 0
                var arrives = t + late
                if block > 0 { arrives = (arrives / block).rounded(.up) * block }
                pendingBurst.append(arrives)
                if pendingBurst.count >= burst {
                    // A burst reaches us together, stamped when the last one arrived.
                    let stamp = pendingBurst.last!
                    for _ in pendingBurst { out.append((stamp, .clock)) }
                    pendingBurst = []
                }
                t += 1.0 / 24 * 60 / part.bpm(t - part.at)
                n += 1
            }
            out.append((t + 0.001, .stop))
            ends.append(t)
            ticks.append((t, part.from + Double(n) / 24, part.bpm(t - part.at)))
            previousEnd = t
        }
        out.sort { $0.seconds < $1.seconds }
        // Truth is the ticks as sent, before anything made them late: straight lines between them.
        let starts = parts.map(\.at)
        return ClockRecording(events: out, truth: { time in
            guard let k = starts.lastIndex(where: { $0 <= time }), time < ends[k] else { return nil }
            var lo = 0, hi = ticks.count - 1
            while lo < hi { let mid = (lo + hi + 1) / 2; if ticks[mid].t <= time { lo = mid } else { hi = mid - 1 } }
            let a = ticks[lo], next = lo + 1 < ticks.count ? ticks[lo + 1] : a
            return (a.q + (next.q - a.q) * (next.t > a.t ? min(1, (time - a.t) / (next.t - a.t)) : 0), a.bpm)
        }, length: ends.last ?? 0)
    }
}

struct StampScore: CustomStringConvertible {
    var queries = 0, medianMs = 0.0, p95Ms = 0.0, maxMs = 0.0, within10ms = 0.0, barRight = 0.0, beatRight = 0.0, tempoWorst = 0.0
    var description: String {
        String(format: "%4d stamps · median %5.2f ms · p95 %6.2f ms · max %6.2f ms · within ±10 ms %5.1f%% · bar %5.1f%% · beat %5.1f%% · tempo off by %.1f BPM",
               queries, medianMs, p95Ms, maxMs, within10ms * 100, barRight * 100, beatRight * 100, tempoWorst)
    }
}

final class BarStampScoreTests: XCTestCase {
    static let ticks = 1_000_000_000.0

    /// Stamps at evenly spread moments, skipping the first beat after each transport jump, where no position
    /// can be known better than the first tick.
    func score(_ r: ClockRecording, skip: Double = 0.5, beatsPerBar: Int = 4, every: ClosedRange<Double> = 0.05...0.25) -> StampScore {
        let timeline = ClockTimeline(ticksPerSecond: Self.ticks)
        timeline.beatsPerBar = beatsPerBar
        var i = r.events.startIndex
        var errors: [Double] = [], bars = 0, beats = 0, tempoWorst = 0.0
        var rng = RNG(state: 99)
        var t = 0.0
        var lastJump = -Double.infinity
        while t < r.length {
            t += Double.random(in: every, using: &rng)
            while i < r.events.count, r.events[i].seconds <= t {
                let e = r.events[i]
                timeline.record(e.event, at: UInt64(e.seconds * Self.ticks))
                if case .clock = e.event {} else { lastJump = e.seconds }
                i += 1
            }
            guard t - lastJump > skip, let truth = r.truth(t), let got = timeline.position(at: UInt64(t * Self.ticks)), got.playing else { continue }
            let q = got.quarters ?? 0
            errors.append(abs(q - truth.quarters) * 60 / truth.tempo * 1_000)
            let whole = Int(floor(truth.quarters))
            if got.bar == whole / beatsPerBar + 1 { bars += 1 }
            if got.beat == whole % beatsPerBar + 1 { beats += 1 }
            tempoWorst = max(tempoWorst, abs(got.tempo - truth.tempo))
        }
        errors.sort()
        guard !errors.isEmpty else { return StampScore() }
        return StampScore(queries: errors.count, medianMs: errors[errors.count / 2], p95Ms: errors[errors.count * 95 / 100], maxMs: errors.last!,
                          within10ms: Double(errors.filter { $0 <= 10 }.count) / Double(errors.count),
                          barRight: Double(bars) / Double(errors.count), beatRight: Double(beats) / Double(errors.count), tempoWorst: tempoWorst)
    }

    private func steady(_ bpm: Double, seconds: Double = 90) -> Song { Song(parts: [.init(at: 1, from: 0, length: seconds, bpm: { _ in bpm })]) }

    private func check(_ name: String, _ s: StampScore, within: Double = 0.99, bar: Double = 0.97, beat: Double = 0.97, tempo: Double = 1,
                       file: StaticString = #filePath, line: UInt = #line) {
        print("bar stamps | \(name.padding(toLength: 30, withPad: " ", startingAt: 0)) | \(s)")
        XCTAssertGreaterThan(s.queries, 50, file: file, line: line)
        XCTAssertGreaterThanOrEqual(s.within10ms, within, "\(name): \(s)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(s.barRight, bar, "\(name): \(s)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(s.beatRight, beat, "\(name): \(s)", file: file, line: line)
        XCTAssertLessThanOrEqual(s.tempoWorst, tempo, "\(name): \(s)", file: file, line: line)
    }

    func testSteadyClock() {
        check("120 BPM, perfect clock", score(steady(120).recording()))
        check("60 BPM, perfect clock", score(steady(60).recording()))
        check("174 BPM, perfect clock", score(steady(174).recording()))
    }

    func testJitter() {
        check("120 BPM, 1 ms jitter", score(steady(120).recording(jitter: 0.001)))
        check("120 BPM, 3 ms jitter", score(steady(120).recording(jitter: 0.003)))
        check("174 BPM, 3 ms jitter", score(steady(174).recording(jitter: 0.003)))
        check("70 BPM, 5 ms jitter", score(steady(70).recording(jitter: 0.005)))
    }

    func testClocksReadOffAudioBuffers() {
        // A clock read off a block-based app lands on buffer edges: 256 and 512 samples at 44.1 kHz.
        check("120 BPM, 5.8 ms buffers", score(steady(120).recording(block: 256.0 / 44_100)))
        check("120 BPM, 11.6 ms buffers", score(steady(120).recording(block: 512.0 / 44_100)))
        check("174 BPM, 11.6 ms buffers", score(steady(174).recording(block: 512.0 / 44_100)))
    }

    func testClocksArrivingInBurstsKeepTheBarAndTempo() {
        // A heavily buffered route: 3 clocks at once is 60 ms late, so no stamp can be within 10 ms. It
        // still has to name the right bar and tempo, and the offset setting (FrameClock) can take the lateness out.
        let s = score(steady(120).recording(burst: 3))
        print("bar stamps | 120 BPM, bursts of 3 (limit)    | \(s)")
        XCTAssertGreaterThanOrEqual(s.barRight, 0.95)
        XCTAssertLessThanOrEqual(s.tempoWorst, 1)
    }

    func testTempoChangesMidSong() {
        let ramp = Song(parts: [.init(at: 1, from: 0, length: 60, bpm: { 90 + 50 * min(1, $0 / 60) })])
        check("ramp 90 to 140 BPM", score(ramp.recording(jitter: 0.001)), tempo: 3)
        let step = Song(parts: [.init(at: 1, from: 0, length: 60, bpm: { $0 < 30 ? 100 : 150 })])
        check("jump 100 to 150 BPM", score(step.recording()), within: 0.97, tempo: 52)
    }

    func testLoopingWithSongPositionPointer() {
        // A 4-bar loop at 120: every 8 s back to bar 9.
        let parts = (0..<8).map { i in Song.Part(at: 1 + Double(i) * 8.1, from: 32, length: 8, bpm: { _ in 120 }) }
        check("4-bar loop via position", score(Song(parts: parts).recording(jitter: 0.001)))
    }

    func testStopLocateContinue() {
        let song = Song(parts: [.init(at: 1, from: 0, length: 20, bpm: { _ in 100 }),
                                .init(at: 25, from: 64, length: 20, bpm: { _ in 100 }),
                                .init(at: 50, from: 8, length: 20, bpm: { _ in 100 })])
        check("stop, locate, continue", score(song.recording(jitter: 0.001)))
    }

    func testClocksRunningWhileStopped() {
        let song = Song(parts: [.init(at: 3, from: 0, length: 20, bpm: { _ in 128 }), .init(at: 30, from: 32, length: 20, bpm: { _ in 128 })])
        check("clocks while stopped", score(song.recording(jitter: 0.001, idleClocks: true)), tempo: 1)
    }

    func testThreeFour() {
        check("3/4, 90 BPM", score(steady(90).recording(jitter: 0.001), beatsPerBar: 3))
    }

    func testAnHourLong() {
        // Past the history window: the stamp must not drift or lose its place.
        let song = steady(123, seconds: 3_600)
        let r = song.recording(jitter: 0.001)
        check("one hour, 123 BPM", score(r, every: 10...30), within: 0.99)
    }

    func testStampThroughTheAudioClock() {
        // The path a take takes: session frame → host time (latency removed) → position.
        let r = steady(120).recording(jitter: 0.001)
        let timeline = ClockTimeline(ticksPerSecond: Self.ticks)
        for e in r.events { timeline.record(e.event, at: UInt64(e.seconds * Self.ticks)) }
        let clock = FrameClock(hostAtFrameZero: UInt64(1.5 * Self.ticks), sampleRate: 48_000, ticksPerSecond: Self.ticks, latencyFrames: 1_024)
        for seconds in stride(from: 3.0, through: 80.0, by: 7.3) {
            let frame = Int64(seconds * 48_000) + 1_024
            let got = timeline.position(at: clock.host(atOutputFrame: frame))
            let truth = r.truth(1.5 + seconds)!
            XCTAssertEqual((got?.quarters ?? 0) * 500, truth.quarters * 500, accuracy: 10, "ms at 120 BPM, \(seconds) s in")
        }
    }

    func testTheParserReadsAMIDILog() {
        let log = "0.0 FA\n0.02 F8\n1.5 F2 10 02\n1.6 FB\nnot a line\n2.0 FC\n2.1 90 40 7F"
        let events = ClockRecording.parse(log).map(\.event)
        XCTAssertEqual(events, [.start, .clock, .songPosition(sixteenths: 0x10 | 2 << 7), .continue, .stop])
    }

    func testAPositionFromAnOldSidecarStillDecodes() throws {
        let old = #"{"bar":3,"beat":2,"sixteenth":1,"tempo":120,"beatsPerBar":4,"playing":true}"#
        let p = try JSONDecoder().decode(MusicalPosition.self, from: Data(old.utf8))
        XCTAssertNil(p.quarters)
        XCTAssertEqual(p.bar, 3)
    }
}
