import CoreMIDI
import Darwin

/// The virtual MIDI input DAWs send clock + song position to ("Hot Mic Sync").
/// Receives on CoreMIDI's thread, records into the timeline on a private serial queue.
public final class SyncPort {
    public let ticksPerSecond: Double
    private let timeline: ClockTimeline
    private let queue = DispatchQueue(label: "io.bluegum.hotmic.sync")
    private var client = MIDIClientRef()
    private var endpoint = MIDIEndpointRef()

    public init(name: String = "Hot Mic Sync", beatsPerBar: Int = 4) throws {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        ticksPerSecond = 1e9 * Double(info.denom) / Double(info.numer)
        timeline = ClockTimeline(ticksPerSecond: ticksPerSecond)
        timeline.beatsPerBar = beatsPerBar

        var status = MIDIClientCreateWithBlock("Hot Mic" as CFString, &client, nil)
        guard status == noErr else { throw SyncError.coreMIDI("client", status) }
        status = MIDIDestinationCreateWithProtocol(client, name as CFString, ._1_0, &endpoint) { [weak self] list, _ in
            self?.receive(list)
        }
        guard status == noErr else { throw SyncError.coreMIDI("destination", status) }
    }

    deinit {
        MIDIEndpointDispose(endpoint)
        MIDIClientDispose(client)
    }

    public var beatsPerBar: Int {
        get { queue.sync { timeline.beatsPerBar } }
        set { queue.sync { timeline.beatsPerBar = newValue } }
    }

    public func position(at host: UInt64) -> MusicalPosition? {
        queue.sync { timeline.position(at: host) }
    }

    private func receive(_ list: UnsafePointer<MIDIEventList>) {
        var parsed: [(ClockTimeline.Event, UInt64)] = []
        for packet in list.unsafeSequence() {
            let host = packet.pointee.timeStamp == 0 ? mach_absolute_time() : packet.pointee.timeStamp
            let count = Int(packet.pointee.wordCount)
            withUnsafeBytes(of: packet.pointee.words) { raw in
                for word in raw.bindMemory(to: UInt32.self).prefix(count) {
                    if let event = Self.decode(word) { parsed.append((event, host)) }
                }
            }
        }
        guard !parsed.isEmpty else { return }
        queue.async { [timeline] in for (event, host) in parsed { timeline.record(event, at: host) } }
    }

    /// UMP type 1 (system common / real-time) words.
    static func decode(_ word: UInt32) -> ClockTimeline.Event? {
        guard word >> 28 == 0x1 else { return nil }
        let status = (word >> 16) & 0xFF
        switch status {
        case 0xF8: return .clock
        case 0xFA: return .start
        case 0xFB: return .continue
        case 0xFC: return .stop
        case 0xF2:
            let lsb = Int((word >> 8) & 0x7F), msb = Int(word & 0x7F)
            return .songPosition(sixteenths: lsb | msb << 7)
        default: return nil
        }
    }
}

public enum SyncError: Error, CustomStringConvertible {
    case coreMIDI(String, OSStatus)
    public var description: String {
        switch self { case let .coreMIDI(what, status): return "MIDI \(what) failed (OSStatus \(status))" }
    }
}
