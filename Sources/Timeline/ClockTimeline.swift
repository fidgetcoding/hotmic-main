import Foundation

/// Where the song was at a moment in time.
public struct MusicalPosition: Equatable, Sendable, Codable {
    public var bar: Int            // 1-based
    public var beat: Int           // 1-based within the bar
    public var sixteenth: Int      // 1-based within the beat
    public var tempo: Double       // BPM
    public var beatsPerBar: Int
    public var playing: Bool
    /// Exactly where in the song, in quarter notes from its start, between the clock's ticks (nil in old sidecars).
    public var quarters: Double?

    public init(bar: Int, beat: Int, sixteenth: Int, tempo: Double, beatsPerBar: Int, playing: Bool, quarters: Double? = nil) {
        self.bar = bar; self.beat = beat; self.sixteenth = sixteenth
        self.tempo = tempo; self.beatsPerBar = beatsPerBar; self.playing = playing; self.quarters = quarters
    }
}

/// MIDI transport + clock history → musical position at any host time.
/// Clock = 24 per quarter note; Song Position Pointer counts 16th notes (6 clocks each).
/// Pure value logic: CoreMIDI feeds it from `SyncPort`, tests feed it directly.
public final class ClockTimeline {
    public enum Event: Equatable, Sendable {
        case clock, start, `continue`, stop
        case songPosition(sixteenths: Int)
        /// History folded into one marker when old events are trimmed (internal bookkeeping).
        case anchor(clocks: Int, playing: Bool)
    }

    public var beatsPerBar = 4                 // MIDI clock carries no time signature (spec: 4/4 default)
    private let ticksPerSecond: Double
    private var events: [(host: UInt64, event: Event)] = []
    private let retention: Double = 15 * 60   // seconds of history kept (≥ the scratch audio window)

    public init(ticksPerSecond: Double) { self.ticksPerSecond = ticksPerSecond }

    /// Number of stored events (tests: history must stay bounded).
    var storedEvents: Int { events.count }

    public func record(_ event: Event, at host: UInt64) {
        events.append((host, event))
        // Trim in batches: fold everything older than the retention window into one anchor,
        // keeping the last 48 clocks before it so tempo is still known right after the cutoff.
        guard events.count > 4_096, let first = events.first,
              seconds(host - min(host, first.host)) > retention * 1.25 else { return }
        let cutoff = host - UInt64(retention * ticksPerSecond)
        guard let split = events.firstIndex(where: { $0.host >= cutoff }), split > 0 else { return }
        let state = fold(events[..<split])
        let recentClocks = events[..<split].filter { $0.event == .clock }.suffix(48)
        var kept: [(host: UInt64, event: Event)] = []
        if state.sawTransport { kept.append((events[split - 1].host, .anchor(clocks: state.clocks, playing: state.playing))) }
        tempoSeed = recentClocks.map(\.host)
        events = kept + events[split...]
    }

    /// Clock times from before the last trim, used only for tempo.
    private var tempoSeed: [UInt64] = []

    private struct State {
        var clocks = 0, playing = false, sawTransport = false, clockTimes: [UInt64] = []
        /// Clock times since the transport last started: what a DAW sends while stopped can be another tempo.
        var playingClocks: [UInt64] = []
        /// Clocks counted since the last jump in position: (when, how many had been counted).
        var run: [(host: UInt64, clocks: Int)] = []
    }

    private func fold<C: Collection>(_ slice: C, until host: UInt64 = .max) -> State where C.Element == (host: UInt64, event: Event) {
        var s = State()
        for (time, event) in slice where time <= host {
            switch event {
            case .start: s.clocks = 0; s.playing = true; s.sawTransport = true; s.run = []; s.playingClocks = []
            case .continue: s.playing = true; s.sawTransport = true; s.run = []; s.playingClocks = []
            case .stop: s.playing = false; s.run = []
            case let .songPosition(sixteenths): s.clocks = sixteenths * 6; s.sawTransport = true; s.run = []
            case let .anchor(clocks, playing): s.clocks = clocks; s.playing = playing; s.sawTransport = true; s.run = []
            case .clock:
                s.clockTimes.append(time)
                if s.clockTimes.count > 48 { s.clockTimes.removeFirst() }
                // Per spec, the first clock after Start is the downbeat; count clocks that complete a tick.
                if s.playing {
                    s.clocks += 1
                    s.playingClocks.append(time)
                    if s.playingClocks.count > 48 { s.playingClocks.removeFirst() }
                    s.run.append((time, s.clocks))
                    if s.run.count > Self.fitClocks { s.run.removeFirst() }
                }
            }
        }
        return s
    }

    public func position(at host: UInt64) -> MusicalPosition? {
        let s = fold(events, until: host)
        let times = s.playingClocks.count >= 6 ? s.playingClocks
            : s.clockTimes.count >= 3 ? s.clockTimes : Array((tempoSeed + s.clockTimes).suffix(48))
        guard s.sawTransport, let tempo = tempo(from: times) else { return nil }
        // `clocks` counts ticks elapsed; position is at the last counted tick.
        let quarter = Double(max(0, s.clocks - (s.playing ? 1 : 0))) / 24
        let beatsDone = Int(quarter)
        let sixteenth = Int((quarter - Double(beatsDone)) * 4) + 1
        return MusicalPosition(bar: beatsDone / beatsPerBar + 1, beat: beatsDone % beatsPerBar + 1,
                               sixteenth: sixteenth, tempo: tempo, beatsPerBar: beatsPerBar, playing: s.playing,
                               quarters: exact(s, at: host, tempo: tempo) ?? quarter)
    }

    /// Clocks a straight line is fitted through: a beat's worth, so a tempo change shows within a beat.
    private static let fitClocks = 24

    /// Quarter notes at `host`, between ticks, from a line through the last clocks: a DAW's clock arrives with
    /// jitter and in bursts, and one late tick shouldn't move the stamp. nil until a few clocks have come.
    private func exact(_ s: State, at host: UInt64, tempo: Double) -> Double? {
        guard s.playing, let last = s.run.last else { return nil }
        guard s.run.count >= 6 else {
            let ticks = Double(last.clocks - 1) + seconds(host - min(host, last.host)) * tempo / 60 * 24
            return ticks / 24
        }
        let t0 = last.host
        let xs = s.run.map { -seconds(t0 - min(t0, $0.host)) }, ys = s.run.map { Double($0.clocks - 1) }
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        let den = zip(xs, xs).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - mx) }
        guard den > 0 else { return ys.last.map { $0 / 24 } }
        let slope = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / den
        // Never past the next tick that hasn't come (the transport may have just stopped).
        let ahead = min(seconds(host - min(host, t0)), 2 * 60 / max(tempo, 1) / 24)
        return (my + slope * (ahead - mx)) / 24
    }

    /// From a line through the last clocks, not the gap between two: clocks reach us with jitter and sometimes in
    /// bursts, and any single gap is off. A gap too long for any tempo is the transport: count from after it.
    private func tempo(from times: [UInt64]) -> Double? {
        guard times.count >= 3 else { return nil }
        let gaps = zip(times.dropFirst(), times).map { seconds($0 - $1) }
        let lastJump = gaps.lastIndex { $0 > 0.25 }.map { $0 + 1 } ?? 0
        let run = times[lastJump...]
        guard run.count >= 3, let t0 = run.first else { return nil }
        let xs = run.map { seconds($0 - t0) }
        let n = Double(xs.count), mx = xs.reduce(0, +) / n, my = (n - 1) / 2
        let den = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        guard den > 0 else { return nil }
        let clocksPerSecond = xs.enumerated().reduce(0) { $0 + ($1.element - mx) * (Double($1.offset) - my) } / den
        return (clocksPerSecond * 60 / 24 * 10).rounded() / 10
    }

    private func seconds(_ ticks: UInt64) -> Double { Double(ticks) / ticksPerSecond }
}

/// Maps session audio frames to host time (and back) from one anchor taken at capture start.
public struct FrameClock: Sendable {
    public var hostAtFrameZero: UInt64
    public var sampleRate: Double
    public var ticksPerSecond: Double
    /// Processed-voice latency: frame f of the output corresponds to input frame f − latency.
    public var latencyFrames: Int64
    /// User calibration for DAWs that send clock early/late (spec: ±10 ms target).
    public var offsetSeconds: Double = 0

    public init(hostAtFrameZero: UInt64, sampleRate: Double, ticksPerSecond: Double, latencyFrames: Int64) {
        self.hostAtFrameZero = hostAtFrameZero
        self.sampleRate = sampleRate
        self.ticksPerSecond = ticksPerSecond
        self.latencyFrames = latencyFrames
    }

    public func host(atOutputFrame frame: Int64) -> UInt64 {
        let seconds = Double(frame - latencyFrames) / sampleRate + offsetSeconds
        let delta = seconds * ticksPerSecond
        return delta >= 0 ? hostAtFrameZero + UInt64(delta) : hostAtFrameZero - UInt64(-delta)
    }
}
