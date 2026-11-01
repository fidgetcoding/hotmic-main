import Enrichment
import Foundation

/// One sung line inside one take.
public struct SungLine: Equatable, Sendable, Identifiable {
    public var id: String            // "<takeID>#<n>", stable across rebuilds
    public var takeID: String
    public var text: String
    public var start: Double         // seconds into the take's files
    public var end: Double
    /// Where in the song (fractional bar, 1-based) — only when the DAW clock was running.
    public var bar: Double?
    public var createdAt: Date
}

/// Every version of one line of the song, oldest first.
public struct LineSlot: Equatable, Sendable, Identifiable {
    public var id: String { versions[0].id }
    public var versions: [SungLine]
    /// The version you picked, if any.
    public var keeperID: String?
    /// What goes in the draft: your pick, else the newest version.
    public var chosen: SungLine { versions.first { $0.id == keeperID } ?? versions[versions.count - 1] }
}

/// The songwriting notebook for one session: every pass lined up line by line, so one line of the
/// song shows all the ways you've sung it.
///
/// How passes line up: each new take is aligned against the song's line order so far. Lines that
/// clearly match an existing line (shared words, or the same bar in the DAW) become anchors,
/// kept in order. Lines between two anchors that don't match anything are paired, in order, with
/// the unmatched lines in the same gap of the song: that's a rewritten line ("over the river" →
/// "down by the water"), not a new one. Whatever is left over becomes a new line of the song.
public struct Notebook: Equatable, Sendable {
    public var slots: [LineSlot]

    /// Anchor threshold: share of words (and word pairs) two lines must have in common.
    static let matchThreshold = 0.35
    /// Bars apart that still count as "the same place in the song".
    static let sameBar = 1.0

    public init(takes: [TakeRecord], keepers: Set<String> = []) {
        var slots: [[SungLine]] = []
        for take in takes.sorted(by: { $0.sessionStartSeconds < $1.sessionStartSeconds }) {
            let lines = Self.lines(of: take)
            if !lines.isEmpty { slots = Self.merge(lines, into: slots) }
        }
        self.slots = slots.map { versions in
            LineSlot(versions: versions, keeperID: versions.last { keepers.contains($0.id) }?.id)
        }
    }

    /// The song as it stands: one chosen version per line.
    public var draft: String { slots.map(\.chosen.text).joined(separator: "\n") }

    // MARK: - lines

    /// Splits a take's lyrics into sung lines: a breath (≥ 0.5 s between words), end punctuation,
    /// or 14 words ends a line.
    public static func lines(of take: TakeRecord) -> [SungLine] {
        guard let lyrics = take.lyrics else { return [] }
        var bar: ((Double) -> Double?) = { _ in nil }
        if let p = take.position, p.playing, p.tempo > 0 {
            let first = Double(p.bar) + (Double(p.beat - 1) + Double(p.sixteenth - 1) / 4) / Double(p.beatsPerBar)
            let padding = take.padding ?? 0
            bar = { t in first + (t - padding) * p.tempo / 60 / Double(p.beatsPerBar) }
        }
        func make(_ n: Int, _ text: String, _ start: Double, _ end: Double) -> SungLine {
            SungLine(id: "\(take.id)#\(n)", takeID: take.id, text: text, start: start, end: end, bar: bar(start),
                     createdAt: take.createdAt.addingTimeInterval(start))
        }
        guard !lyrics.words.isEmpty else {
            return LyricIndex.lines(lyrics.text).enumerated().map { make($0.offset, $0.element, 0, take.durationSeconds) }
        }
        var out: [SungLine] = []
        var current: [Lyrics.Word] = []
        func close() {
            let words = current.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if LyricIndex.words(words).count >= 2, let first = current.first, let last = current.last {
                out.append(make(out.count, words, first.start, last.end))
            }
            current = []
        }
        for word in lyrics.words where !word.text.isEmpty {
            if let last = current.last {
                let breath = word.start - last.end >= 0.5
                let stop = last.text.last.map { ".!?;".contains($0) } ?? false
                let comma = last.text.hasSuffix(",") && current.count >= 5
                if breath || stop || comma || current.count >= 14 { close() }
            }
            current.append(word)
        }
        close()
        return out
    }

    // MARK: - alignment

    static func merge(_ lines: [SungLine], into slots: [[SungLine]]) -> [[SungLine]] {
        let n = lines.count, m = slots.count
        let score: [[Double]] = lines.map { line in slots.map { similarity(line, $0) } }
        // Order-preserving best set of anchors (weighted LCS): only clear matches earn points.
        var dp = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        for i in 1...max(1, n) where n > 0 {
            for j in 1...max(1, m) where m > 0 {
                let s = score[i - 1][j - 1]
                let take = s >= matchThreshold ? dp[i - 1][j - 1] + s : -1
                dp[i][j] = max(dp[i - 1][j], dp[i][j - 1], take)
            }
        }
        var anchors: [(line: Int, slot: Int)] = []
        var i = n, j = m
        while i > 0, j > 0 {
            let s = score[i - 1][j - 1]
            if s >= matchThreshold, dp[i][j] == dp[i - 1][j - 1] + s { anchors.append((i - 1, j - 1)); i -= 1; j -= 1 }
            else if dp[i][j] == dp[i - 1][j] { i -= 1 }
            else { j -= 1 }
        }
        anchors.reverse()

        // Rebuild the song gap by gap (virtual anchors before the start and after the end).
        var result: [[SungLine]] = []
        var prev = (line: -1, slot: -1)
        for anchor in anchors + [(n, m)] {
            let gapLines = Array(lines[(prev.line + 1)..<anchor.line])
            var gapSlots = Array(slots[(prev.slot + 1)..<anchor.slot])
            var leftover: [SungLine] = []
            var k = 0
            for line in gapLines {
                // Same place in the song (in order) = a rewrite of that line.
                while k < gapSlots.count, !samePlace(line, gapSlots[k]) { k += 1 }
                if k < gapSlots.count { gapSlots[k].append(line); k += 1 } else { leftover.append(line) }
            }
            result += gapSlots
            result += leftover.map { [$0] }
            if anchor.line < n { result.append(slots[anchor.slot] + [lines[anchor.line]]) }
            prev = anchor
        }
        return result
    }

    /// A rewrite can only take a line's place if it's sung at the same point of the song
    /// (when the DAW clock tells us bars); without bars, order is all we have.
    static func samePlace(_ line: SungLine, _ slot: [SungLine]) -> Bool {
        guard let bar = line.bar else { return true }
        let bars = slot.compactMap(\.bar)
        return bars.isEmpty || bars.contains { abs($0 - bar) <= 2 * sameBar }
    }

    /// 0…1: best match against any version of the slot, plus a boost for the same bar.
    static func similarity(_ line: SungLine, _ slot: [SungLine]) -> Double {
        slot.map { version -> Double in
            var s = textSimilarity(line.text, version.text)
            if let a = line.bar, let b = version.bar, abs(a - b) <= sameBar { s += 0.35 }
            return min(1, s)
        }.max() ?? 0
    }

    /// Average of word overlap (ignoring filler words) and word-pair overlap (Dice).
    public static func textSimilarity(_ a: String, _ b: String) -> Double {
        let wa = LyricIndex.words(a), wb = LyricIndex.words(b)
        guard !wa.isEmpty, !wb.isEmpty else { return 0 }
        func content(_ w: [String]) -> Set<String> {
            let c = Set(w.filter { !LyricIndex.stop.contains($0) })
            return c.isEmpty ? Set(w) : c
        }
        func pairs(_ w: [String]) -> Set<String> {
            guard w.count >= 2 else { return Set(w) }
            var out = Set<String>()
            for k in 0..<(w.count - 1) { out.insert("\(w[k]) \(w[k + 1])") }
            return out
        }
        func dice(_ x: Set<String>, _ y: Set<String>) -> Double {
            let shared = Double(x.intersection(y).count)
            return 2 * shared / Double(x.count + y.count)
        }
        return 0.5 * dice(content(wa), content(wb)) + 0.5 * dice(pairs(wa), pairs(wb))
    }

    // MARK: - diff

    /// `text`'s words, each flagged when it isn't part of the longest run shared with `reference`
    /// — the words you changed.
    public static func diff(_ text: String, against reference: String) -> [(word: String, changed: Bool)] {
        let tokens = text.split(separator: " ").map(String.init)
        let a = tokens.map { LyricIndex.words($0).joined() }, b = reference.split(separator: " ").map { LyricIndex.words(String($0)).joined() }
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var out: [(String, Bool)] = []
        var i = 0, j = 0
        while i < a.count {
            if j < b.count, a[i] == b[j] { out.append((tokens[i], false)); i += 1; j += 1 }
            else if j < b.count, lcs[i][j + 1] >= lcs[i + 1][j] { j += 1 }
            else { out.append((tokens[i], true)); i += 1 }
        }
        return out
    }
}

/// Your keeper picks for a session, in `notebook.json` next to the takes.
public struct NotebookStore {
    public static let fileName = "notebook.json"
    public let folder: URL
    public init(folder: URL) { self.folder = folder }

    private struct File: Codable { var keepers: [String] }
    private var url: URL { folder.appendingPathComponent(Self.fileName) }

    public func keepers() -> Set<String> {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return Set(file.keepers)
    }

    /// Keep `version` for its line (clears any other pick in the same line). Picking the current
    /// keeper again un-picks it.
    public func pick(_ version: String, in slot: LineSlot) throws {
        var keepers = self.keepers()
        let wasKeeper = keepers.contains(version)
        keepers.subtract(slot.versions.map(\.id))
        if !wasKeeper { keepers.insert(version) }
        let data = try JSONEncoder().encode(File(keepers: keepers.sorted()))
        try data.write(to: url, options: .atomic)
    }

    /// Writes the current draft as `draft.md` (the chosen version of every line).
    public func writeDraft(_ notebook: Notebook, title: String) throws -> URL {
        let out = folder.appendingPathComponent("draft.md")
        try "# \(title)\n\n\(notebook.draft)\n".write(to: out, atomically: true, encoding: .utf8)
        return out
    }
}
