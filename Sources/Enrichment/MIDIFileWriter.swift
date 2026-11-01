import Foundation

/// Standard MIDI File, format 0: tempo, time signature, then the notes. 480 ticks per quarter.
public enum MIDIFileWriter {
    public static let ticksPerQuarter = 480

    /// `channel` is 0-based; 9 = General MIDI drums.
    public static func data(notes: [Note], tempo: Double, beatsPerBar: Int = 4, trackName: String = "Hot Mic",
                            channel: UInt8 = 0) -> Data {
        let secondsToTicks = tempo / 60 * Double(ticksPerQuarter)
        var events: [(tick: Int, bytes: [UInt8])] = []
        let name = Array(trackName.utf8.prefix(127))
        events.append((0, [0xFF, 0x03, UInt8(name.count)] + name))
        let micros = Int((60_000_000 / tempo).rounded())
        events.append((0, [0xFF, 0x51, 0x03, UInt8(micros >> 16 & 0xFF), UInt8(micros >> 8 & 0xFF), UInt8(micros & 0xFF)]))
        events.append((0, [0xFF, 0x58, 0x04, UInt8(beatsPerBar), 2, 24, 8]))
        for note in notes {
            let on = Int((note.start * secondsToTicks).rounded())
            let off = max(on + 1, Int(((note.start + note.duration) * secondsToTicks).rounded()))
            let pitch = UInt8(max(0, min(127, note.pitch)))
            events.append((on, [0x90 | channel, pitch, UInt8(max(1, min(127, note.velocity)))]))
            events.append((off, [0x80 | channel, pitch, 0]))
        }
        // Stable sort: at equal ticks, note-offs before note-ons so repeated pitches retrigger.
        events = events.enumerated().sorted { a, b in
            if a.element.tick != b.element.tick { return a.element.tick < b.element.tick }
            let aOff = a.element.bytes.first.map { $0 & 0xF0 == 0x80 } ?? false
            let bOff = b.element.bytes.first.map { $0 & 0xF0 == 0x80 } ?? false
            return aOff != bOff ? aOff : a.offset < b.offset
        }.map(\.element)

        var track = [UInt8]()
        var last = 0
        for event in events {
            track += vlq(event.tick - last) + event.bytes
            last = event.tick
        }
        track += [0x00, 0xFF, 0x2F, 0x00]

        var out = Data("MThd".utf8)
        out += be32(6) + be16(0) + be16(1) + be16(ticksPerQuarter)
        out += Data("MTrk".utf8) + be32(track.count) + Data(track)
        return out
    }

    /// Drum hits as 60 ms notes on channel 10.
    public static func drums(_ hits: [DrumHit], tempo: Double, beatsPerBar: Int = 4, trackName: String = "Hot Mic Drums") -> Data {
        data(notes: hits.map { Note(pitch: $0.note, sungPitch: Double($0.note), start: $0.time, duration: 0.06, velocity: $0.velocity) },
             tempo: tempo, beatsPerBar: beatsPerBar, trackName: trackName, channel: 9)
    }

    static func vlq(_ value: Int) -> [UInt8] {
        var v = max(0, value)
        var bytes = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 { bytes.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
        return bytes
    }

    private static func be32(_ v: Int) -> Data { Data([UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
    private static func be16(_ v: Int) -> Data { Data([UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
}
