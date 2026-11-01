import Enrichment
import Foundation

/// A take's MIDI cut into pieces you can drop straight into a DAW: one clip per sung line, and
/// one per 4-bar phrase. Every clip starts on the downbeat of the bar its first note is in, so
/// dropped on that bar it lines up.
public enum MIDISlices {
    public struct Slice: Equatable, Sendable {
        public var name: String          // file name, no extension
        public var start: Double         // seconds into the take: notes starting in [start, end) belong here
        public var end: Double
        public var anchor: Double        // seconds into the take that become MIDI time 0 (a downbeat)
    }

    /// Where bars fall in the take: the DAW's clock when it was running, else the detected tempo
    /// with the first note as a downbeat (jam mode).
    public struct BarGrid: Equatable, Sendable {
        public var firstDownbeat: Double  // seconds into the take of a downbeat (may be negative)
        public var firstBarNumber: Int    // that downbeat's bar number
        public var secondsPerBar: Double
        public var beatsPerBar: Int
        public var tempo: Double
        public var fromDAW: Bool

        public func bar(at t: Double) -> Int { firstBarNumber + Int(floor((t - firstDownbeat) / secondsPerBar + 1e-6)) }
        public func downbeat(ofBar bar: Int) -> Double { firstDownbeat + Double(bar - firstBarNumber) * secondsPerBar }
    }

    public static func grid(for take: TakeRecord) -> BarGrid? {
        if let p = take.position, p.playing, p.tempo > 0 {
            let spb = 60 / p.tempo
            let into = (Double(p.beat - 1) + Double(p.sixteenth - 1) / 4) * spb
            return BarGrid(firstDownbeat: (take.padding ?? 0) - into, firstBarNumber: p.bar,
                           secondsPerBar: spb * Double(p.beatsPerBar), beatsPerBar: p.beatsPerBar, tempo: p.tempo, fromDAW: true)
        }
        if let t = take.tempo, t.confidence > 0.2, let first = take.midiNotes?.map(\.start).min() {
            return BarGrid(firstDownbeat: first, firstBarNumber: 1, secondsPerBar: 4 * 60 / t.bpm, beatsPerBar: 4,
                           tempo: t.bpm, fromDAW: false)
        }
        return nil
    }

    /// One slice per sung line (needs lyrics with word timings).
    public static func lines(for take: TakeRecord) -> [Slice] {
        let lines = Notebook.lines(of: take)
        let grid = grid(for: take)
        return lines.enumerated().map { n, line in
            // A line owns everything until the next line starts (held last notes stay whole).
            let start = max(0, line.start - 0.15)
            let end = n + 1 < lines.count ? lines[n + 1].start - 0.15 : take.durationSeconds
            // The bar of the first sung word (80 ms early still counts as on the downbeat).
            let anchor = grid.map { $0.downbeat(ofBar: $0.bar(at: line.start + 0.08)) } ?? start
            return Slice(name: String(format: "line-%02d %@", n + 1, safe(firstWords(line.text))), start: start, end: end, anchor: anchor)
        }
    }

    /// One slice per `bars`-bar phrase that has notes in it (needs a tempo).
    public static func phrases(for take: TakeRecord, bars: Int = 4) -> [Slice] {
        guard let grid = grid(for: take), let notes = take.midiNotes, !notes.isEmpty else { return [] }
        var starts = Set<Int>()
        for note in notes {
            let bar = grid.bar(at: note.start)
            starts.insert(grid.firstBarNumber + ((bar - grid.firstBarNumber) / bars) * bars - (bar < grid.firstBarNumber ? bars : 0))
        }
        return starts.sorted().map { first in
            let last = first + bars - 1
            return Slice(name: String(format: "bars %03d-%03d", first, last), start: grid.downbeat(ofBar: first),
                         end: grid.downbeat(ofBar: last + 1), anchor: grid.downbeat(ofBar: first))
        }
    }

    /// The slice as a Standard MIDI File: notes starting inside it, timed from its anchor.
    public static func data(_ slice: Slice, take: TakeRecord, trackName: String? = nil) -> Data? {
        guard let notes = take.midiNotes else { return nil }
        let inside = notes.filter { $0.start >= slice.start && $0.start < slice.end }.map { note -> Note in
            var n = note
            n.start -= slice.anchor
            if n.start < 0 { n.duration = max(0.02, n.duration + n.start); n.start = 0 }   // pickup before the downbeat
            return n
        }
        guard !inside.isEmpty else { return nil }
        let grid = grid(for: take)
        return MIDIFileWriter.data(notes: inside, tempo: grid?.tempo ?? take.position?.tempo ?? 120,
                                   beatsPerBar: grid?.beatsPerBar ?? 4, trackName: trackName ?? slice.name)
    }

    /// Writes every line and phrase clip into `<take>__midi/` next to the take; returns the folder.
    @discardableResult
    public static func write(_ take: TakeRecord, in sessionFolder: URL) throws -> URL {
        let folder = sessionFolder.appendingPathComponent("\(take.id)__midi", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for slice in lines(for: take) + phrases(for: take) {
            guard let data = data(slice, take: take) else { continue }
            try data.write(to: folder.appendingPathComponent("\(slice.name).mid"), options: .atomic)
        }
        return folder
    }

    /// Writes just one line's clip (for dragging from the notebook); nil when the line has no notes.
    public static func writeLine(_ index: Int, of take: TakeRecord, in sessionFolder: URL) -> URL? {
        let slices = lines(for: take)
        guard slices.indices.contains(index), let data = data(slices[index], take: take) else { return nil }
        let folder = sessionFolder.appendingPathComponent("\(take.id)__midi", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(slices[index].name).mid")
        return (try? data.write(to: url, options: .atomic)) == nil ? nil : url
    }

    static func firstWords(_ text: String) -> String {
        text.split(separator: " ").prefix(4).joined(separator: " ")
    }

    static func safe(_ s: String) -> String {
        String(s.map { "/:\\?*\"<>|".contains($0) ? "-" : $0 }).trimmingCharacters(in: .whitespaces)
    }
}
