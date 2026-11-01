import Foundation

/// Where the song was at a moment in time.
public struct MusicalPosition: Equatable, Sendable, Codable {
    public var bar: Int            // 1-based
    public var beat: Int           // 1-based within the bar
    public var sixteenth: Int      // 1-based within the beat
    public var tempo: Double       // BPM
    public var beatsPerBar: Int
    public var playing: Bool

    public init(bar: Int, beat: Int, sixteenth: Int, tempo: Double, beatsPerBar: Int, playing: Bool) {
        self.bar = bar; self.beat = beat; self.sixteenth = sixteenth
        self.tempo = tempo; self.beatsPerBar = beatsPerBar; self.playing = playing
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

    private struct State { var clocks = 0, playing = false, sawTransport = false, clockTimes: [UInt64] = [] }

    private func fold<C: Collection>(_ slice: C, until host: UInt64 = .max) -> State where C.Element == (host: UInt64, event: Event) {
        var s = State()
        for (time, event) in slice where time <= host {
            switch event {
            case .start: s.clocks = 0; s.playing = true; s.sawTransport = true
            case .continue: s.playing = true; s.sawTransport = true
            case .stop: s.playing = false
            case let .songPosition(sixteenths): s.clocks = sixteenths * 6; s.sawTransport = true
            case let .anchor(clocks, playing): s.clocks = clocks; s.playing = playing; s.sawTransport = true
            case .clock:
                s.clockTimes.append(time)
                if s.clockTimes.count > 48 { s.clockTimes.removeFirst() }
                // Per spec, the first clock after Start is the downbeat; count clocks that complete a tick.
                if s.playing { s.clocks += 1 }
            }
        }
        return s
    }

    public func position(at host: UInt64) -> MusicalPosition? {
        let s = fold(events, until: host)
        let times = s.clockTimes.count >= 3 ? s.clockTimes : Array((tempoSeed + s.clockTimes).suffix(48))
        guard s.sawTransport, let tempo = tempo(from: times) else { return nil }
        // `clocks` counts ticks elapsed; position is at the last counted tick.
        let quarter = Double(max(0, s.clocks - (s.playing ? 1 : 0))) / 24
        let beatsDone = Int(quarter)
        let sixteenth = Int((quarter - Double(beatsDone)) * 4) + 1
        return MusicalPosition(bar: beatsDone / beatsPerBar + 1, beat: beatsDone % beatsPerBar + 1,
                               sixteenth: sixteenth, tempo: tempo, beatsPerBar: beatsPerBar, playing: s.playing)
    }

    private func tempo(from times: [UInt64]) -> Double? {
        guard times.count >= 3 else { return nil }
        var intervals = zip(times.dropFirst(), times).map { seconds($0 - $1) }.sorted()
        intervals = intervals.filter { $0 > 0 }
        guard !intervals.isEmpty else { return nil }
        let median = intervals[intervals.count / 2]
        return (60 / (median * 24) * 10).rounded() / 10
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
