import Enrichment
import Foundation

/// Lines you sang, as the live recognizer heard them, kept in the session folder (live-lines.json).
/// They show the moment you finish a line and never disappear; Whisper's lyrics replace a live line
/// only where a take's transcription actually covers that stretch of the session.
public struct LiveLine: Codable, Equatable, Sendable {
    public var text: String
    /// Session seconds.
    public var at: Double
    public var end: Double
    /// Whisper on this line's own audio, a second or so after you finish it. Shown instead of `text`.
    public var fixed: String?
    /// You hit Stop while still singing this line (it shows with a stop mark).
    public var cut: Bool?
    /// You typed or pasted this line, so lyrics written elsewhere can go straight in.
    public var typed: Bool?

    public init(text: String, at: Double, end: Double, fixed: String? = nil, cut: Bool? = nil, typed: Bool? = nil) {
        self.text = text; self.at = at; self.end = end; self.fixed = fixed; self.cut = cut; self.typed = typed
    }

    /// What to show: Whisper's version when it has real words, else what the live recognizer heard.
    public var shown: String { fixed.flatMap { LiveLines.isJunk($0) ? nil : $0 } ?? text }
}

public enum LiveLines {
    public static let fileName = "live-lines.json"

    public static func read(_ folder: URL) -> [LiveLine] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return [] }
        return (try? JSONDecoder().decode([LiveLine].self, from: data)) ?? []
    }

    public static func append(_ line: LiveLine, to folder: URL) {
        var all = read(folder)
        all.append(line)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(all) { try? data.write(to: folder.appendingPathComponent(fileName), options: .atomic) }
    }

    /// Lines you typed or pasted: one per non-empty line of `text`, placed from `at` on, in order.
    public static func type(_ text: String, at: Double, to folder: URL) {
        let rows = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for (i, row) in rows.enumerated() {
            append(LiveLine(text: row, at: at + Double(i) * 0.01, end: at + Double(i) * 0.01 + 0.005, typed: true), to: folder)
        }
    }

    /// Records Whisper's version of the line that starts at `at`.
    public static func fix(at: Double, text: String, in folder: URL) {
        var all = read(folder)
        guard let i = all.firstIndex(where: { abs($0.at - at) < 0.01 }) else { return }
        all[i].fixed = text
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(all) { try? data.write(to: folder.appendingPathComponent(fileName), options: .atomic) }
    }

    /// What Whisper writes when it hears no words: "*sad music*", "[Music]", "(applause)", "♪".
    /// Never shown as a lyric.
    public static func isJunk(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || Lyrics.isLoop(t) { return true }
        let stripped = t.replacingOccurrences(of: #"[\*\[\]\(\)♪♫\-–—.…\s]"#, with: "", options: .regularExpression)
        if stripped.isEmpty { return true }
        let wrapped = t.range(of: #"^[\*\[\(♪♫].*[\*\]\)♪♫]$"#, options: .regularExpression) != nil
        let tags = ["music", "applause", "silence", "inaudible", "blank_audio", "laugh", "noise", "humming", "singing", "instrumental"]
        let words = t.split(whereSeparator: \.isWhitespace).count
        return wrapped || (words <= 4 && tags.contains { t.lowercased().contains($0) } && t.range(of: #"[\*\[\(]"#, options: .regularExpression) != nil)
    }
}
