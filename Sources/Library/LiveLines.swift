import Capture
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
    private static let lock = NSLock()

    /// Display-only fallback. Mutations always use readChecked so damaged data is never replaced.
    public static func read(_ folder: URL) -> [LiveLine] {
        (try? readChecked(folder)) ?? []
    }

    public static func readChecked(_ folder: URL) throws -> [LiveLine] {
        try PersistenceFile.read(folder.appendingPathComponent(fileName), default: [LiveLine]())
    }

    private static func update(in folder: URL, _ change: (inout [LiveLine]) -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        do {
            var all = try readChecked(folder)
            guard change(&all) else { return false } // no line matched, so nothing was saved
            try PersistenceFile.write(all, to: folder.appendingPathComponent(fileName), pretty: true)
            return true
        } catch { return false } // PersistenceFile already logged the failure
    }

    /// False reports a failed save. Read/encode failures leave existing data untouched; writes are atomic.
    @discardableResult
    public static func append(_ line: LiveLine, to folder: URL) -> Bool {
        update(in: folder) { $0.append(line); return true }
    }

    /// Lines you typed or pasted: one per non-empty line, in one atomic write. Empty input is a no-op.
    @discardableResult
    public static func type(_ text: String, at: Double, to folder: URL) -> Bool {
        let rows = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !rows.isEmpty else { return true }
        return update(in: folder) { all in
            all.append(contentsOf: rows.enumerated().map { i, row in
                LiveLine(text: row, at: at + Double(i) * 0.01, end: at + Double(i) * 0.01 + 0.005, typed: true)
            })
            return true
        }
    }

    /// Records Whisper's version. False if the line is missing or its file could not be saved.
    @discardableResult
    public static func fix(at: Double, text: String, in folder: URL) -> Bool {
        update(in: folder) { all in
            guard let i = all.firstIndex(where: { abs($0.at - at) < 0.01 }) else {
                HotMicLog.write("persistence update skipped for live-lines.json: no matching line")
                return false
            }
            all[i].fixed = text
            return true
        }
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
