import Enrichment
import Foundation

/// Writes lyrics into a take's sidecar and rebuilds the session's `lyrics.md` sheet:
/// every take in order, headed by bar + section + time, so each pass of a freestyle stacks up.
public enum LyricSheet {
    public static let fileName = "lyrics.md"

    /// One writer at a time: lyric jobs finish in any order and each rebuilds the sheet.
    private static let queue = DispatchQueue(label: "io.bluegum.hotmic.lyricsheet")

    public static func attach(_ lyrics: Lyrics, echoes: [EchoNote] = [], toTake id: String, in folder: URL) throws {
        try queue.sync { try attachLocked(lyrics, echoes: echoes, toTake: id, in: folder) }
    }

    private static func attachLocked(_ lyrics: Lyrics, echoes: [EchoNote], toTake id: String, in folder: URL) throws {
        let url = folder.appendingPathComponent("\(id).json")
        var record = try decoder.decode(TakeRecord.self, from: Data(contentsOf: url))
        record.lyrics = lyrics
        record.echoes = echoes.isEmpty ? nil : echoes
        try encoder.encode(record).write(to: url, options: .atomic)
        try rebuild(folder)
    }

    public static func rebuild(_ folder: URL) throws {
        let records = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(TakeRecord.self, from: Data(contentsOf: $0)) }
            .filter { !($0.lyrics?.text.isEmpty ?? true) }
            .sorted { $0.sessionStartSeconds < $1.sessionStartSeconds }
        var out = "# Lyrics — \(folder.lastPathComponent)\n"
        for r in records {
            var head: [String] = []
            if let p = r.position, p.playing { head.append("Bar \(p.bar)") }
            if let s = r.section { head.append("Section \(s)\(r.sectionSource == "audio-guess" ? " (guess)" : "")") }
            head.append(clock.string(from: r.createdAt))
            out += "\n### \(head.joined(separator: " · "))\n\n\(r.lyrics!.text)\n"
            for e in r.echoes ?? [] { out += "\n> ↺ “\(e.line)” — already in \(e.from)\n" }
        }
        try out.write(to: folder.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        return f
    }()
}
