import AVFoundation
import Foundation
import Enrichment

/// A session as the Hot Mic window (the web UI in `ui/`) reads it: every sung line with all its versions,
/// built by the app's own Notebook, so the window shows exactly what the app made of your singing.
/// Shared by the app window and the `hotmic-export` CLI (which feeds the design lab).
public struct LabSession: Encodable, Sendable {
    public struct Word: Encodable, Sendable { public let w: String; public let start: Double; public let end: Double }
    public struct Version: Encodable, Sendable {
        public let id: String; public let takeID: String; public let text: String
        public let start: Double; public let end: Double; public let at: Double
        public let words: [Word]; public let chords: [String]; public let keeper: Bool
        /// The notes you sang on this line ("A3 C4 D4"), from a sung/hummed take's melody; empty for rap and talk.
        public var notes: [String] = []
    }
    public struct Take: Encodable, Sendable {
        public let id: String; public let at: Double; public let dur: Double
        public let voice: String?; public let mix: String?; public let confidence: Float; public let key: String?
    }
    public let id: String
    public let name: String
    public let folder: String
    public let length: Double
    public let takes: [Take]
    public let slots: [[Version]]
    /// The whole recording's loudness, `envRate` values a second, 0…255 (−50…0 dBFS peak).
    public var env: [UInt8] = []
    public var envRate: Double = Double(LabSessionExport.waveformRate)
    /// The whole recording (session__voice_001.m4a, _002…, 5 minutes each): what plays when you click a word.
    public var sessionAudio: [String] = []
    /// The same recording with what the Mac played (in Beat mode: the beat) — what Beat-mode playback uses.
    public var sessionMix: [String] = []
    public var segmentSeconds: Double = 300
    /// Beat-mode recordings: where the beat was when each started (for looped playback in sync).
    public var beatRuns: [BeatRun] = []
    /// Stretches you deleted (hidden, audio kept).
    public var hidden: [HiddenRange] = []
}

/// One row in the window's Sessions list.
public struct LabSessionItem: Encodable, Sendable {
    public let id: String
    public let name: String
    public let date: String
    public let daw: String
    public let takes: Int
    public let length: Double
}

public enum LabSessionExport {
    /// Reads a session folder (take sidecars + your keeper picks) into a `LabSession`.
    public static func session(folder: URL) -> LabSession {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let takes = files
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != NotebookStore.fileName }
            .compactMap { url -> TakeRecord? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return (try? LyricSheet.decoder.decode(TakeRecord.self, from: data)) ?? (try? JSONDecoder().decode(TakeRecord.self, from: data))
            }
            .sorted { $0.sessionStartSeconds < $1.sessionStartSeconds }
        // The lines themselves: one pure function, the same one the scenario harness runs.
        let liveRaw = LiveLines.read(folder)
        // Your own words (slang, names) that Whisper may not overwrite: one per line, at the top of the Hot Mic folder.
        let wordsFile = folder.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Your words.txt")
        let protected = Set(((try? String(contentsOf: wordsFile, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty && !$0.hasPrefix("#") })
        let hidden = HiddenRanges.read(folder)
        let slots = HiddenRanges.filter(sungNotes(takes, wordless(takes, into: LyricArranger.arrange(takes: takes, keepers: NotebookStore(folder: folder).keepers(), live: liveRaw, protected: protected))), hidden)
        let livePart = slots.filter { $0.contains { $0.takeID.isEmpty || $0.takeID == "typed" } }

        let exTakes = takes.map { t in
            LabSession.Take(id: t.id, at: t.sessionStartSeconds, dur: t.durationSeconds,
                            voice: t.files["voice"].map { folder.appendingPathComponent($0).path },
                            mix: t.files["mix"].map { folder.appendingPathComponent($0).path },
                            confidence: t.confidence, key: t.key.map { "\($0)" })
        }
        let length = max(exTakes.map { $0.at + $0.dur }.max() ?? 0, livePart.compactMap { $0.first.map { $0.at + $0.end } }.max() ?? 0)
        var out = LabSession(id: folder.path, name: folder.lastPathComponent, folder: folder.path,
                             length: length > 0 ? length + 5 : 0, takes: exTakes, slots: slots)
        out.env = waveform(folder: folder)
        out.beatRuns = BeatRuns.read(folder)
        out.hidden = hidden
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        out.sessionAudio = names.filter { $0.hasPrefix("session__voice_") && $0.hasSuffix(".m4a") }.sorted()
            .map { folder.appendingPathComponent($0).path }
        out.sessionMix = names.filter { $0.hasPrefix("session__mix_") && $0.hasSuffix(".m4a") }.sorted()
            .map { folder.appendingPathComponent($0).path }
        return out
    }

    static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// Each sung line gets the notes you sang on it (Nate 2026-10-14: "tell you what notes you're singing"),
    /// from the melody of a singing take under it. Rap, talk and playing takes give none, so spoken words never show notes.
    static func sungNotes(_ takes: [TakeRecord], _ slots: [[LabSession.Version]]) -> [[LabSession.Version]] {
        let sung = takes.filter { ($0.kind ?? "singing") == "singing" && !($0.midiNotes ?? []).isEmpty }
        guard !sung.isEmpty else { return slots }
        return slots.map { $0.map { v in
            guard v.notes.isEmpty, !v.text.hasPrefix("hum"), !v.text.hasPrefix("chords") else { return v }
            let a = v.at, b = v.at + max(0.3, v.end - v.start)
            var names: [String] = []
            for t in sung where t.sessionStartSeconds < b && t.sessionStartSeconds + t.durationSeconds > a {
                for n in t.midiNotes ?? [] {
                    let at = t.sessionStartSeconds + n.start
                    guard at >= a - 0.2, at < b + 0.2, n.duration >= 0.08 else { continue }
                    let name = noteNames[((n.pitch % 12) + 12) % 12] + "\(n.pitch / 12 - 1)"
                    if names.last != name { names.append(name) }
                }
            }
            var out = v; out.notes = Array(names.prefix(16)); return out
        } }
    }

    /// Takes with no words (a hum, beatboxing) get a row of their own at the time you did them, so they
    /// show in the notepad instead of only in the take count (Nate 2026-10-13). A hum's "words" are its
    /// melody notes (click one to hear it); beatboxing is one "beat" word. Takes with lyrics, takes
    /// already in a row, playing-only takes and any take a live line covers are left alone.
    static func wordless(_ takes: [TakeRecord], into slots: [[LabSession.Version]]) -> [[LabSession.Version]] {
        let used = Set(slots.flatMap { $0.map(\.takeID) })
        let live = slots.flatMap { $0 }.filter { $0.takeID.isEmpty }.map { ($0.at, $0.at + ($0.end - $0.start)) }
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        var extra: [[LabSession.Version]] = []
        for t in takes where !used.contains(t.id) && (t.lyrics?.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            let kind = t.kind ?? "singing"
            guard ["singing", "whisper", "rap", "beatbox"].contains(kind) else { continue }
            let (a, b) = (t.sessionStartSeconds, t.sessionStartSeconds + t.durationSeconds)
            if live.contains(where: { $0.0 < b && $0.1 > a }) { continue }
            let pad = t.padding ?? 0, end = max(0.5, t.durationSeconds - pad)
            var words: [LabSession.Word]
            let label: String
            if kind == "beatbox" {
                label = "beat"; words = [LabSession.Word(w: "beat", start: pad, end: end)]
            } else {
                label = "hum"
                words = (t.midiNotes ?? []).prefix(16).map {
                    LabSession.Word(w: names[(($0.pitch % 12) + 12) % 12] + "\($0.pitch / 12 - 1)", start: $0.start, end: $0.start + $0.duration)
                }
                if words.isEmpty { words = [LabSession.Word(w: "hum", start: pad, end: end)] }
            }
            let text = label == "hum" && words.first?.w != "hum" ? "hum · " + words.map(\.w).joined(separator: " ") : label
            extra.append([LabSession.Version(id: "\(label)-\(t.id)", takeID: t.id, text: text, start: 0, end: t.durationSeconds,
                                             at: t.sessionStartSeconds, words: words, chords: [], keeper: false)])
        }
        extra += chordRows(takes, around: slots.flatMap { $0 }.map { ($0.at, $0.at + ($0.end - $0.start)) })
        guard !extra.isEmpty else { return slots }
        let at = { (row: [LabSession.Version]) in row.first?.at ?? 0 }
        return (slots + extra).enumerated().sorted { (at($0.element), $0.offset) < (at($1.element), $1.offset) }.map(\.element)
    }

    /// Playing with no words over it (a long intro, a solo) gets a chords row, "chords · Eb Gm Ab", so the
    /// stretch shows in the notepad (Nate 2026-10-13: "played a long intro and no chords were identified").
    /// Chords under a sung line stay off; a run breaks where a line sits or after 2 s with no chord.
    static func chordRows(_ takes: [TakeRecord], around lines: [(Double, Double)]) -> [[LabSession.Version]] {
        var rows: [[LabSession.Version]] = []
        for t in takes where t.kind == "playing" {
            let t0 = t.sessionStartSeconds
            let spans = (t.chords ?? []).filter { c in
                c.name != "N" && !lines.contains { $0.0 - 0.5 < t0 + c.end && $0.1 + 0.5 > t0 + c.start }
            }
            var runs: [[ChordSpan]] = []
            for c in spans {
                if let prev = runs.last?.last, c.start - prev.end <= 2,
                   !lines.contains(where: { $0.0 >= t0 + prev.end && $0.0 <= t0 + c.start }) { runs[runs.count - 1].append(c) } else { runs.append([c]) }
            }
            for run in runs {
                guard let a = run.first?.start, let b = run.last?.end, b - a >= 3 else { continue }
                var names: [ChordSpan] = []
                for c in run where names.last?.name != c.name { names.append(c) }
                let words = names.prefix(16).map { LabSession.Word(w: $0.name, start: $0.start - a, end: $0.end - a) }
                rows.append([LabSession.Version(id: "chords-\(t.id)-\(Int(a * 10))", takeID: t.id,
                                                text: "chords · " + words.map(\.w).joined(separator: " "), start: 0, end: b - a,
                                                at: t0 + a, words: words, chords: Array(Set(words.map(\.w))).sorted(), keeper: false)])
            }
        }
        return rows
    }

    /// Splits Whisper's words into the live lines they belong to: word alignment (edit distance on
    /// normalized words), each Whisper word goes to the line of the live word it lines up with; extra
    /// words stay with the line before them. A live line Whisper skipped comes back empty.
    static func pour(_ whisper: [String], into live: [[String]]) -> [[String]] { pourSplit(whisper, into: live).lines }

    /// Same, plus the Whisper words sung after the last live word (the recognizer missed them).
    static func pourSplit(_ whisper: [String], into live: [[String]]) -> (lines: [[String]], overflow: [String]) {
        let norm = { (w: String) in w.lowercased().filter { $0.isLetter || $0.isNumber } }
        let flat = live.enumerated().flatMap { i, ws in ws.map { (line: i, w: norm($0)) } }
        let a = whisper.map(norm), n = a.count, m = flat.count
        var out = [[String]](repeating: [], count: live.count)
        guard n > 0, m > 0 else { return (out, whisper) }
        func cost(_ x: String, _ y: String) -> Int { x == y || (x.count > 2 && y.count > 2 && (x.hasPrefix(y) || y.hasPrefix(x))) ? 0 : 1 }
        var d = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        for i in 1...n { for j in 1...m { d[i][j] = min(d[i - 1][j - 1] + cost(a[i - 1], flat[j - 1].w), d[i - 1][j] + 1, d[i][j - 1] + 1) } }
        var lineOf = [Int?](repeating: nil, count: n)
        var i = n, j = m
        while i > 0 && j > 0 {
            if d[i][j] == d[i - 1][j - 1] + cost(a[i - 1], flat[j - 1].w) { lineOf[i - 1] = flat[j - 1].line; i -= 1; j -= 1 }
            else if d[i][j] == d[i - 1][j] + 1 { i -= 1 } else { j -= 1 }
        }
        let lastAligned = lineOf.lastIndex { $0 != nil } ?? -1
        var line = lineOf.compactMap { $0 }.first ?? 0, overflow: [String] = []
        for k in 0..<n {
            if k > lastAligned { overflow.append(whisper[k]); continue }
            if let l = lineOf[k] { line = max(line, l) }
            out[line].append(whisper[k])
        }
        // A break mid-phrase (the live line hit its word limit while you kept going): pull the rest of
        // the phrase up, up to the next comma within 4 words ("a good | day," → "a good day,").
        let ends = { (w: String) in w.last.map { ",.!?;".contains($0) } ?? false }
        for i in 0..<max(0, out.count - 1) where !(out[i].last.map(ends) ?? true) {
            if let k = out[i + 1].prefix(4).firstIndex(where: ends) {
                out[i] += out[i + 1][...k]; out[i + 1].removeFirst(k + 1)
            }
        }
        if !out.isEmpty, !(out[out.count - 1].last.map(ends) ?? true), let k = overflow.prefix(4).firstIndex(where: ends) {
            out[out.count - 1] += overflow[...k]; overflow.removeFirst(k + 1)
        }
        return (out, overflow)
    }

    /// The same line sung again (a loop, a line you keep reworking) is a new VERSION of it, not a new
    /// line: half or more of its words match an earlier line. The newest version shows unless you star one.
    static func groupVersions(_ slots: [[LabSession.Version]]) -> [[LabSession.Version]] {
        var out: [[LabSession.Version]] = []
        var previous: String?        // the line sung just before this one
        for slot in slots {
            guard slot.count == 1, let v = slot.first, words(v.text).count >= 2 else { out.append(slot); previous = slot.last?.text; continue }
            // A line sung right after a similar one is a repeat (a chorus, a hook sung three times:
            // Nate 2026-10-12), never a version. Versions come from reworking a line after other lines.
            let sungAgain = previous.map { similarity($0, v.text) >= 0.5 } ?? false
            if !sungAgain, let j = out.lastIndex(where: { $0.contains { sameLine($0.text, v.text) } }) {
                out[j].append(v)
            } else {
                out.append(slot)
            }
            previous = v.text
        }
        return out
    }

    static let fillers: Set<String> = ["um", "uh", "yeah", "so", "like", "oh", "ah", "the", "a", "and", "i", "it", "you", "know"]

    /// Two lines are versions of one line: half their words shared (at least one real word, not just
    /// "um": 2026-10-13 "where, um" / "fireman, um"), or a retake whose live cut swallowed a whole earlier
    /// line ("saying stuff it's gonna start registering what you're saying then if…" holds all 7 words of
    /// "it's gonna start registering what you're saying": Nate's "two different versions" test).
    static func sameLine(_ a: String, _ b: String) -> Bool {
        let x = words(a), y = words(b)
        let shared = Set(x).intersection(y).subtracting(fillers)
        guard !shared.isEmpty else { return false }   // "that boy" / "that guy" are versions (Nate, C8)
        if similarity(a, b) >= 0.5 { return !keepsOnlyTheOpening(a, b) }
        let short = x.count <= y.count ? x : y, long = Set(x.count <= y.count ? y : x)
        return short.count >= 5 && Double(short.filter(long.contains).count) / Double(short.count) >= 0.85
    }

    /// A line that keeps only its opening and goes somewhere else ("I'm feeling good tonight" →
    /// "I'm feeling kinda tired") is a new line, not a version (Nate 2026-10-13, C6). Only when little
    /// else matches: a line that keeps most of its words is still a version ("…the morning comes/calls").
    static func keepsOnlyTheOpening(_ a: String, _ b: String) -> Bool {
        let x = words(a), y = words(b)
        guard x.count >= 4, y.count >= 4, similarity(a, b) < 0.6 else { return false }
        return Array(x.prefix(2)) == Array(y.prefix(2)) && x.last != y.last
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map { w in
            var w = String(w)
            if w.hasSuffix("'s") { w.removeLast(2) }
            if w.count > 3, w.hasSuffix("s"), !w.hasSuffix("ss") { w.removeLast() }   // cars ≈ car, stops ≈ stop
            return w
        }
    }

    /// Shared words over the longer line's length (repeats counted once each side).
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var pool: [String: Int] = [:]
        for w in y { pool[w, default: 0] += 1 }
        var common = 0
        for w in x where (pool[w] ?? 0) > 0 { pool[w]! -= 1; common += 1 }
        return Double(common) / Double(max(x.count, y.count))
    }

    /// One word on its own is never a line (Nate 2026-10-12): it joins the line before it (the first
    /// line's joins the one after). Two words can stand alone. Lines with alternate versions are left be.
    static func foldLoneWords(_ slots: [[LabSession.Version]]) -> [[LabSession.Version]] {
        let count = { (v: LabSession.Version) in v.text.split(whereSeparator: \.isWhitespace).count }
        var out: [[LabSession.Version]] = []
        for slot in slots {
            guard slot.count == 1, let v = slot.first, count(v) == 1, v.takeID != "typed" else { out.append(slot); continue }
            if let prev = out.last, prev.count == 1, let p = prev.first, p.takeID != "typed" {
                out[out.count - 1] = [p.appending(v)]
            } else {
                out.append(slot)
            }
        }
        if out.count > 1, out[0].count == 1, out[1].count == 1, let v = out[0].first, count(v) == 1, let n = out[1].first {
            out[1] = [v.appending(n)]; out.removeFirst()
        }
        return out
    }

    /// Cuts loose words into lines: a comma or full stop after 4+ words, or 10 words.
    static func chunk(_ words: [String]) -> [[String]] {
        var out: [[String]] = [], cur: [String] = []
        for w in words {
            cur.append(w)
            if cur.count >= 10 || (cur.count >= 4 && (w.hasSuffix(",") || w.hasSuffix(".") || w.hasSuffix("?") || w.hasSuffix("!"))) { out.append(cur); cur = [] }
        }
        if !cur.isEmpty {
            if cur.count <= 1, !out.isEmpty { out[out.count - 1] += cur } else { out.append(cur) }   // no one-word stragglers
        }
        return out
    }

    public static let waveformRate = 20

    /// The strip's waveform from the whole-session recording (session__voice_*.m4a), cached beside it
    /// as session__waveform.dat. A segment still being written can't be read yet: it's left out
    /// (live levels draw the part being recorded) and nothing is cached.
    public static func waveform(folder: URL) -> [UInt8] {
        let fm = FileManager.default
        let segments = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("session__voice_") && $0.pathExtension == "m4a" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !segments.isEmpty else { return [] }
        let cache = folder.appendingPathComponent("session__waveform.dat")
        let modified = { (u: URL) in (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        let newest = segments.map(modified).max() ?? .distantPast
        if fm.fileExists(atPath: cache.path), modified(cache) >= newest, let data = try? Data(contentsOf: cache) { return [UInt8](data) }
        var out: [UInt8] = [], complete = true
        for url in segments {
            guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { complete = false; continue }
            let rate = file.processingFormat.sampleRate, hop = max(1, Int(rate) / waveformRate)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(hop * 50)) else { continue }
            var peak: Float = 0, count = 0
            while file.framePosition < file.length {
                guard (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData, buffer.frameLength > 0 else { break }
                for i in 0..<Int(buffer.frameLength) {
                    peak = max(peak, abs(data[0][i])); count += 1
                    if count == hop {
                        let level = max(0, min(1, (20 * log10(peak + 1e-6) + 50) / 50))
                        out.append(UInt8(level * 255)); peak = 0; count = 0
                    }
                }
            }
        }
        if complete { try? Data(out).write(to: cache) }
        return out
    }

    /// The Sessions list, newest first.
    public static func list(_ index: LibraryIndex) -> [LabSessionItem] {
        let iso = ISO8601DateFormatter()
        return index.sessions().map { s in
            LabSessionItem(id: s.id, name: s.name, date: iso.string(from: s.date), daw: s.daw, takes: s.takes.count,
                           length: s.takes.map { $0.sessionStartSeconds + $0.durationSeconds }.max() ?? 0)
        }
    }

    /// JSON for the web UI.
    public static func json<T: Encodable>(_ value: T) -> String {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
}

extension LabSession.Version {
    /// This line followed by `next` as one line (times stay in the session's clock).
    func appending(_ next: LabSession.Version) -> LabSession.Version {
        let (first, second) = at <= next.at ? (self, next) : (next, self)
        let shift = second.at - first.at
        let words = first.words + second.words.map { LabSession.Word(w: $0.w, start: $0.start + shift, end: $0.end + shift) }
        var chords = first.chords
        for c in second.chords where !chords.contains(c) { chords.append(c) }
        // A pause between the two shows as a comma ("That boy, yeah": Nate 2026-10-12). No pause (the
        // recognizer cut mid-phrase: "a good" + "day") or punctuation already there: just a space.
        let gap = second.at - (first.at + first.end - first.start)
        let punctuated = first.text.last.map { ",.!?;:—…".contains($0) } ?? false
        let seam = gap < LyricArranger.pauseComma || punctuated ? " " : ", "
        return LabSession.Version(id: first.id, takeID: first.takeID, text: first.text + seam + second.text,
                                  start: first.start, end: max(first.end, first.start + shift + (second.end - second.start)),
                                  at: first.at, words: words, chords: Array(chords.prefix(3)), keeper: first.keeper || second.keeper)
    }
}
