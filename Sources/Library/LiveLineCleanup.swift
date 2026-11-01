import Foundation

/// Cleans the live lines before they're arranged (Nate's 2026-10-13 late test, session "233010 Jam"):
/// - an old recognition request finishing late commits the same words twice ("as soon" + "as", both 22.7–23.0 s);
/// - each line's Whisper clip reaches 1.4 s back and 0.6 s forward, so the fix picks up the end of the line
///   before and the start of the line after ("…then if there's an obvious," when the next line is
///   "there's an obvious break…");
/// - Whisper sometimes says a phrase twice ("split them as I need to and you know, split them as I need to").
/// Pure: the window and the lyric harness run the same rule.
public enum LiveLineCleanup {
    public static func clean(_ lines: [LiveLine]) -> [LiveLine] {
        var lines = dropDuplicates(lines)
        // A short line the line before already ends with (its Whisper clip, which runs 0.6 s past its end, ran into it: "…there's a loop mode" then "loop").
        lines = lines.enumerated().filter { i, l in
            guard i > 0, l.typed != true, let prevFix = lines[i - 1].fixed else { return true }
            let w = norm(l.shown), tail = norm(prevFix).suffix(6)
            return !(w.count <= 3 && !w.isEmpty && l.at < lines[i - 1].end + 0.6 && containsRun(Array(tail), w))
        }.map(\.element)
        return lines.indices.map { i in
            var l = lines[i]
            guard let fixed = l.fixed, !LiveLines.isJunk(fixed) else { return l }
            let prev = i > 0 ? lines[i - 1].text : nil
            let next = i + 1 < lines.count ? lines[i + 1].text : nil
            let trimmed = trim(fixed, previous: prev, next: next)
            l.fixed = trimmed.isEmpty ? nil : trimmed
            return l
        }
    }

    /// A line over the same span as the one before whose words are all in it: the same words, committed twice.
    static func dropDuplicates(_ lines: [LiveLine]) -> [LiveLine] {
        var out: [LiveLine] = []
        for l in lines {
            if l.typed != true, let p = out.last, p.typed != true, abs(p.at - l.at) < 0.15, abs(p.end - l.end) < 0.15 {
                let a = Set(norm(p.text)), b = norm(l.text)
                if b.allSatisfy(a.contains) { continue }
                if Set(b).isSuperset(of: a) { out[out.count - 1] = l; continue }
            }
            out.append(l)
        }
        return out
    }

    /// Whisper's text for one line, without the neighbours' words it overheard, a doubled phrase, or double spaces.
    public static func trim(_ text: String, previous: String?, next: String?) -> String {
        var ws = text.split(whereSeparator: \.isWhitespace).map(String.init)
        ws = collapseRepeat(ws)
        if let next {
            let head = norm(next)
            // Longest run at the end of this line that starts the next line (the clip's last word may be cut short).
            // At most 5 overheard words, and never most of the line (a chorus sung twice is not bleed).
            for k in stride(from: min(ws.count / 3, head.count, 5), through: 2, by: -1) {
                let tail = ws.suffix(k).map(normWord)
                let exact = Array(tail) == Array(head.prefix(k))
                let cutShort = k >= 3 && Array(tail.dropLast()) == Array(head.prefix(k - 1)) && head.count >= k
                    && head[k - 1].hasPrefix(String(tail.last!.prefix(2)))
                if exact || cutShort { ws.removeLast(k); break }
            }
        }
        if let previous {
            let tailP = norm(previous)
            for k in stride(from: min(ws.count / 3, tailP.count, 4), through: 2, by: -1) {
                if ws.prefix(k).map(normWord) == Array(tailP.suffix(k)) { ws.removeFirst(k); break }
            }
        }
        var out = ws.joined(separator: " ")
        while out.hasSuffix(",") { out.removeLast() }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// "A B C D x y A B C D" → "A B C D x y": a phrase of 4+ words said again at the very end is Whisper repeating itself.
    static func collapseRepeat(_ ws: [String]) -> [String] {
        let n = ws.map(normWord)
        guard n.count >= 8 else { return ws }
        for k in stride(from: n.count / 2, through: 4, by: -1) {
            let end = Array(n.suffix(k))
            for s in 0...(n.count - 2 * k) where Array(n[s..<(s + k)]) == end { return Array(ws.prefix(n.count - k)) }
        }
        return ws
    }

    static func containsRun(_ hay: [String], _ run: [String]) -> Bool {
        guard run.count <= hay.count else { return false }
        return (0...(hay.count - run.count)).contains { Array(hay[$0..<($0 + run.count)]) == run }
    }

    static func normWord(_ w: String) -> String {
        w.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
    }
    static func norm(_ s: String) -> [String] {
        s.split(whereSeparator: \.isWhitespace).map { normWord(String($0)) }.filter { !$0.isEmpty }
    }
}
