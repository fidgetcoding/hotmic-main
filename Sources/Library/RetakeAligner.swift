import Foundation

/// A pass sung again with its line breaks in different places still pairs line for line (Nate 2026-10-14:
/// the second pass of session "233010 Jam" cut "saying stuff it's gonna start registering… then if there's an
/// obvious" where the first pass had three lines). The retake's words are aligned against the earlier lines'
/// words as one sequence (longest common subsequence over the whole stretch, not line by line); each retake
/// word lands on the earlier line its match belongs to, and the pieces become versions of those lines.
/// A line sung right after the one it matches is a repeat (a chorus), never a version, so the matched lines
/// must end at least one line before the retake.
enum RetakeAligner {
    static let window = 14          // earlier lines to align against
    static let minShare = 0.6       // of the retake's words matched, in order
    static let joinGap = 2.5        // seconds: retake pieces this close on the same earlier line join

    static func align(_ slots: [[LabSession.Version]]) -> [[LabSession.Version]] {
        var out: [[LabSession.Version]] = []
        var retakeOf: [Int: (id: String, end: Double)] = [:]     // slot index → the retake version last added there
        for slot in slots {
            guard slot.count == 1, let v = slot.first, v.takeID.isEmpty, let pieces = pieces(v, against: out) else { out.append(slot); continue }
            for (j, piece) in pieces {
                if let last = retakeOf[j], let k = out[j].lastIndex(where: { $0.id == last.id }), piece.at - last.end < joinGap {
                    out[j][k] = out[j][k].appending(piece)
                } else {
                    out[j].append(piece)
                }
                let added = out[j].last { $0.id == piece.id || $0.id == retakeOf[j]?.id }!
                retakeOf[j] = (added.id, added.at + (added.end - added.start))
            }
        }
        return out
    }

    /// Retake pieces of one line sung back to back (the live recognizer cut the retake mid-line: "as soon as
    /// you start" + "saying stuff") are one version. The first version (the original) is never merged into.
    static func joinFragments(_ slots: [[LabSession.Version]]) -> [[LabSession.Version]] {
        slots.map { slot in
            guard slot.count >= 3 else { return slot }
            let first = slot[0]
            var rest: [LabSession.Version] = []
            for v in slot.dropFirst().sorted(by: { $0.at < $1.at }) {
                if let p = rest.last, !p.keeper, !v.keeper, v.at - (p.at + p.end - p.start) < 1.0, v.at >= p.at { rest[rest.count - 1] = p.appending(v) }
                else { rest.append(v) }
            }
            return [first] + rest
        }
    }

    /// The retake cut into pieces, each with the index of the earlier line it re-sings; nil when it isn't a retake.
    static func pieces(_ v: LabSession.Version, against out: [[LabSession.Version]]) -> [(Int, LabSession.Version)]? {
        let words = v.text.split(whereSeparator: \.isWhitespace).map(String.init)
        let norm = words.map(key)
        guard norm.filter({ !$0.isEmpty }).count >= 4, out.count >= 2 else { return nil }
        // A line that matches one earlier line whole is left to the usual version rule (and its chorus guard).
        if out.contains(where: { $0.contains { LabSessionExport.sameLine($0.text, v.text) && LabSessionExport.similarity($0.text, v.text) >= 0.5 } }) { return nil }
        let from = max(0, out.count - window)
        var ref: [String] = [], owner: [Int] = []
        for j in from..<out.count {
            guard let first = out[j].first, first.takeID != "typed" else { continue }
            for w in first.text.split(whereSeparator: \.isWhitespace) { ref.append(key(String(w))); owner.append(j) }
        }
        guard !ref.isEmpty else { return nil }
        // LCS table.
        let n = norm.count, m = ref.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for k in stride(from: m - 1, through: 0, by: -1) {
                dp[i][k] = !norm[i].isEmpty && norm[i] == ref[k] ? dp[i + 1][k + 1] + 1 : max(dp[i + 1][k], dp[i][k + 1])
            }
        }
        var line = [Int?](repeating: nil, count: n)
        var i = 0, k = 0
        while i < n, k < m {
            if !norm[i].isEmpty, norm[i] == ref[k] { line[i] = owner[k]; i += 1; k += 1 }
            else if dp[i + 1][k] >= dp[i][k + 1] { i += 1 } else { k += 1 }
        }
        let matched = line.compactMap { $0 }
        guard Double(matched.count) >= minShare * Double(n), matched.count >= 3,
              let lastLine = matched.max(), lastLine < out.count - 1 else { return nil }
        // Unmatched words go with the matched word before them (or after, at the start).
        var fill = line
        var prev: Int? = nil
        for idx in 0..<n { if let l = fill[idx] { prev = l } else { fill[idx] = prev } }
        var next: Int? = nil
        for idx in stride(from: n - 1, through: 0, by: -1) { if let l = fill[idx] { next = l } else { fill[idx] = next } }
        // Contiguous runs → pieces; a one-word piece joins its neighbour.
        var runs: [(line: Int, words: [Int])] = []
        for idx in 0..<n { let l = fill[idx]!; if runs.last?.line == l { runs[runs.count - 1].words.append(idx) } else { runs.append((l, [idx])) } }
        var merged: [(line: Int, words: [Int])] = []
        for r in runs {
            if r.words.count < 2, var last = merged.popLast() { last.words += r.words; merged.append(last) } else { merged.append(r) }
        }
        if merged.count > 1, merged[0].words.count < 2 { merged[1].words = merged[0].words + merged[1].words; merged.removeFirst() }
        guard merged.count >= 2 else { return nil }     // it re-sings one line: the usual version rule decides
        let dur = v.end - v.start, per = dur / Double(max(1, n))
        return merged.enumerated().map { p, r in
            let a = Double(r.words.first!) * per, b = Double(r.words.last! + 1) * per
            let ws = r.words.map { words[$0] }, step = (b - a) / Double(max(1, ws.count))
            return (r.line, LabSession.Version(id: "\(v.id)#al\(p)", takeID: v.takeID, text: ws.joined(separator: " "),
                                               start: v.start + a, end: v.start + b, at: v.at + a,
                                               words: ws.enumerated().map { LabSession.Word(w: $1, start: Double($0) * step, end: Double($0 + 1) * step) },
                                               chords: v.chords, keeper: v.keeper))
        }
    }

    static func key(_ w: String) -> String {
        LabSessionExport.words(w).first ?? ""
    }
}
