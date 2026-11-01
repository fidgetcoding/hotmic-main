import Foundation
import Enrichment

/// A recognized word with the time it was heard (session or request seconds).
public struct TimedWord: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}

/// Every rule that turns what you sang into the lines of the sheet, as pure functions of data, so the
/// lyric scenario harness (Tests/LibraryTests/LyricScenarioTests.swift) can run the same code the
/// window runs, on fixtures, without a session folder or a microphone.
///
/// Two stages:
/// 1. `lines(words:)` — the live recognizer's cut: how a stream of timed words becomes lines as you sing.
/// 2. `arrange(takes:keepers:live:)` — the sheet: take lyrics and live lines (with Whisper's per-line
///    corrections) become slots of versions, in order, with stray words folded and repeats grouped.
public enum LyricArranger {
    /// A pause this long between words ends a line.
    public static let lineGap = 0.9
    /// A line never runs past this many words (the recognizer is restarted at the cut).
    public static let maxWords = 16
    /// A pause this long between two pieces that join shows as a comma; shorter means the recognizer
    /// cut mid-phrase, and the pieces are one phrase (Nate 2026-10-12: "That boy, yeah" / "a good day").
    public static let pauseComma = 0.4
    /// Whisper's commas end a line once it has this many words (shorter phrases pull together).
    public static let phraseWords = 4

    /// Ad-libs ("yeah", "uh", "ay", "oh", "yo"…) are set off with commas (Nate 2026-10-12: "comma after ad lib").
    public static let adLibs: Set<String> = ["yeah", "yea", "yuh", "uh", "ay", "ayy", "aye", "oh", "ooh", "woo", "hey", "yo", "huh", "mm", "mhm", "uh-huh"]

    /// "yeah come around" → "yeah, come around"; "and everybody fly yeah" → "and everybody fly, yeah";
    /// "yeah yeah you already know" → "yeah, yeah, you already know". A run of ad-libs in the middle gets a
    /// comma on both sides. Punctuation already there is left alone.
    static func adLibCommas(_ text: String) -> String {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count > 1 else { return text }
        let bare = { (w: String) in w.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.!?;:—…\"'")) }
        let isAd = words.map { adLibs.contains(bare($0)) }
        guard isAd.contains(true), isAd.contains(false) else { return text }
        let punctuated = { (w: String) in w.last.map { ",.!?;:—…".contains($0) } ?? false }
        for i in words.indices {
            guard isAd[i] else { continue }
            let next = i + 1 < words.count ? words[i + 1] : nil
            // After the ad-lib: a comma when the next word is a lyric, or the same ad-lib again.
            if let n = next, !punctuated(words[i]), (!isAd[i + 1] || bare(n) == bare(words[i])) { words[i] += "," }
            // Before the ad-lib: a comma on the lyric word before it.
            if i > 0, !isAd[i - 1], !punctuated(words[i - 1]) { words[i - 1] += "," }
        }
        return words.joined(separator: " ")
    }

    /// Lines start lowercase except "I" (Nate 2026-10-13, D13). Names inside a line keep their capital.
    static func lowercaseStart(_ text: String) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        let word = text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        if word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") { return text }
        return String(first).lowercased() + text.dropFirst()
    }

    /// No comma or period at the end of a line (Nate 2026-10-13, D12); ? and ! stay, so do the marks.
    static func trimLineEnd(_ text: String) -> String {
        var t = text
        var mark = ""
        for m in [" ⏹"] where t.hasSuffix(m) { mark = m; t = String(t.dropLast(m.count)) }
        if let r = t.range(of: #" ×\d+$"#, options: .regularExpression) { mark = String(t[r]) + mark; t = String(t[..<r.lowerBound]) }
        while let last = t.last, ",.;:".contains(last) { t.removeLast() }
        return t + mark
    }

    /// A false start is dropped (Nate 2026-10-13, B8): a short line whose words open the line sung right
    /// after it ("I'm feeling" then "I'm feeling good tonight"), at most 3 words or half the next line.
    static func dropFalseStarts(_ slots: [[LabSession.Version]]) -> [[LabSession.Version]] {
        var out: [[LabSession.Version]] = []
        for (i, slot) in slots.enumerated() {
            if slot.count == 1, let v = slot.first, v.takeID.isEmpty, i + 1 < slots.count, slots[i + 1].count == 1, let n = slots[i + 1].first, n.takeID.isEmpty {
                let a = LabSessionExport.words(v.text), b = LabSessionExport.words(n.text)
                if !a.isEmpty, a.count <= max(3, b.count / 2), a.count < b.count, Array(b.prefix(a.count)) == a { continue }
            }
            out.append(slot)
        }
        return out
    }

    /// The same line three or more times in a row (a hook you drill) shows once, marked ×N (Nate 2026-10-13,
    /// C16). Twice stays written out (C1). Provisional until "drilling vs chorus" is settled.
    static func collapseRepeats(_ slots: [[LabSession.Version]]) -> [[LabSession.Version]] {
        var out: [[LabSession.Version]] = []
        var i = 0
        while i < slots.count {
            guard slots[i].count == 1, let v = slots[i].first, v.takeID.isEmpty else { out.append(slots[i]); i += 1; continue }
            var j = i + 1
            while j < slots.count, slots[j].count == 1, let w = slots[j].first, w.takeID.isEmpty, LabSessionExport.similarity(v.text, w.text) >= 0.9 { j += 1 }
            let n = j - i
            if n >= 3, let last = slots[j - 1].first {
                let end = (last.at + last.end - last.start) - v.at
                out.append([LabSession.Version(id: v.id, takeID: v.takeID, text: v.text + " ×\(n)", start: v.start, end: v.start + end, at: v.at,
                                               words: v.words, chords: v.chords, keeper: v.keeper)])
            } else {
                for k in i..<j { out.append(slots[k]) }
            }
            i = j
        }
        return out
    }

    /// Whisper's fix dropped a word you keep in your own list ("finna", "aight"…): the live words stay
    /// (Nate 2026-10-13, D10). The list lives in "Your words.txt" at the top of the Hot Mic folder.
    static func keepProtected(_ line: LiveLine, protected: Set<String>) -> String {
        guard let fixed = line.fixed, !protected.isEmpty else { return line.shown }
        let live = Set(LabSessionExport.words(line.text)), fix = Set(LabSessionExport.words(fixed))
        return live.contains(where: { protected.contains($0) && !fix.contains($0) }) ? line.text : line.shown
    }

    /// A line that starts right where the one before it ended (no pause) continues it: the recognizer
    /// cut mid-phrase (its word limit, or a restart). They become one line, re-cut at Whisper's commas below.
    static func joinContinuations(_ slots: [[LabSession.Version]]) -> [[LabSession.Version]] {
        var out: [[LabSession.Version]] = []
        for slot in slots {
            guard slot.count == 1, let v = slot.first, let prev = out.last, prev.count == 1, let p = prev.first, p.takeID.isEmpty, v.takeID.isEmpty else { out.append(slot); continue }
            let gap = v.at - (p.at + p.end - p.start)
            let punctuated = p.text.last.map { ",.!?;:—…".contains($0) } ?? false
            if gap < pauseComma, !punctuated, !p.text.hasSuffix("⏹") { out[out.count - 1] = [p.appending(v)] } else { out.append(slot) }
        }
        return out
    }

    /// Lines end where phrases end (Nate 2026-10-12): Whisper's commas and periods cut a line once it has
    /// `phraseWords` words; a short tail joins the line before it. Only lines heard live (Whisper's take-level
    /// text is already cut by the notebook's rules).
    static func recutAtCommas(_ slots: [[LabSession.Version]]) -> [[LabSession.Version]] {
        var out: [[LabSession.Version]] = []
        for slot in slots {
            guard slot.count == 1, let v = slot.first, v.takeID.isEmpty || v.id.hasSuffix("#pour"), v.text.contains(where: { ",.;!?".contains($0) }) else { out.append(slot); continue }
            // Phrases: the text split after each comma/period, punctuation kept on the phrase.
            var phrases: [[String]] = [[]]
            for w in v.text.split(whereSeparator: \.isWhitespace).map(String.init) {
                phrases[phrases.count - 1].append(w)
                if w.last.map({ ",.;!?".contains($0) }) ?? false { phrases.append([]) }
            }
            phrases = phrases.filter { !$0.isEmpty }
            var lines: [[String]] = [], cur: [String] = []
            for ph in phrases {
                cur += ph
                if cur.count >= phraseWords { lines.append(cur); cur = [] }
            }
            if !cur.isEmpty { if lines.isEmpty { lines.append(cur) } else { lines[lines.count - 1] += cur } }
            guard lines.count > 1 else { out.append(slot); continue }
            // Each new line gets its share of the old line's time, by word position.
            let total = Double(lines.reduce(0) { $0 + $1.count }), span = v.end - v.start
            var pos = 0
            for (k, ws) in lines.enumerated() {
                let a = span * Double(pos) / total, b = span * Double(pos + ws.count) / total
                pos += ws.count
                let step = (b - a) / Double(max(1, ws.count))
                out.append([LabSession.Version(id: "\(v.id)#c\(k)", takeID: v.takeID, text: ws.joined(separator: " "),
                                               start: v.start + a, end: v.start + b, at: v.at + a,
                                               words: ws.enumerated().map { LabSession.Word(w: $1, start: Double($0) * step, end: Double($0 + 1) * step) },
                                               chords: v.chords, keeper: v.keeper)])
            }
        }
        return out
    }

    /// Cuts timed words into lines: a gap of `lineGap` or more, or `maxWords`, starts a new line.
    /// `voiced(a, b)` says you kept making sound between two words (a mumble the recognizer gave no
    /// words for): that gap doesn't cut, so the sentence stays one line and Whisper fills the mumble
    /// (Nate 2026-10-13). Lines still end at `maxWords` or `maxSpan` seconds.
    public static let maxSpan = 8.0
    public static func lines(words: [TimedWord], voiced: ((Double, Double) -> Bool)? = nil) -> [[TimedWord]] {
        var out: [[TimedWord]] = []
        for w in words {
            if let line = out.last, let prev = line.last, let first = line.first, line.count < maxWords,
               w.start - prev.end < lineGap || (w.end - first.start < maxSpan && voiced?(prev.end, w.start) == true) {
                out[out.count - 1].append(w)
            } else {
                out.append([w])
            }
        }
        return out
    }

    /// What the window shows for one session: every line with all its versions, oldest first, in the
    /// order sung. `takes` are the session's take sidecars, `keepers` your starred take versions,
    /// `live` the lines heard while you sang (with Whisper's per-line corrections where they landed).
    public static func arrange(takes: [TakeRecord], keepers: Set<String>, live liveIn: [LiveLine], protected: Set<String> = []) -> [[LabSession.Version]] {
        let liveRaw = LiveLineCleanup.clean(liveIn.sorted { $0.at < $1.at })
        let takes = takes.sorted { $0.sessionStartSeconds < $1.sessionStartSeconds }
        let protected = Set(protected.map { $0.lowercased() })
        let notebook = Notebook(takes: takes, keepers: keepers)
        let byID = Dictionary(takes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Chords only where an instrument played (Nate 2026-10-14: "if all I've done is say a word" there are no chords).
        func chords(_ t: TakeRecord, _ a: Double, _ b: Double) -> [String] {
            guard t.kind == "playing" else { return [] }
            var out: [String] = []
            for s in (t.chords ?? []) where s.name != "N" && s.end > a && s.start < b && out.last != s.name { out.append(s.name) }
            return Array(out.prefix(2))
        }
        var slots: [[LabSession.Version]] = notebook.slots.map { slot in
            slot.versions.map { v in
                let t = byID[v.takeID]
                let words = (t?.lyrics?.words ?? [])
                    .filter { $0.start >= v.start - 0.05 && $0.end <= v.end + 0.05 }
                    .map { LabSession.Word(w: $0.text.trimmingCharacters(in: .whitespaces), start: $0.start - v.start, end: $0.end - v.start) }
                return LabSession.Version(id: v.id, takeID: v.takeID, text: v.text, start: v.start, end: v.end,
                                          at: (t?.sessionStartSeconds ?? 0) + v.start, words: words,
                                          chords: t.map { chords($0, v.start, v.end) } ?? [], keeper: slot.keeperID == v.id)
            }
        }
        // Whisper's "*sad music*" and friends are not lyrics.
        slots = slots.map { $0.filter { !LiveLines.isJunk($0.text) } }.filter { !$0.isEmpty }

        // A take you sang with live lines: Whisper's words, cut at your live line breaks and placed at
        // their times. Whisper's own word timings drift badly on long takes (2026-10-12: 25 words all at 0.2 s).
        let liveAll = liveRaw.filter { !LiveLines.isJunk($0.text) }
        let liveTakesSelfFix = true      // per-line Whisper (LiveWords → LiveLines.fix) is the source of corrections
        var poured = Set<String>(), pouredSlots: [[LabSession.Version]] = []
        var replacedLive = Set<Double>()     // live lines a take's transcription stands in for (by start time)
        for t in takes {
            guard let lyr = t.lyrics, !LiveLines.isJunk(lyr.text) else { continue }
            let span = (t.sessionStartSeconds - 0.3)...(t.sessionStartSeconds + t.durationSeconds + 0.3)
            let inTake = liveAll.filter { span.contains(($0.at + $0.end) / 2) }.sorted { $0.at < $1.at }
            guard !inTake.isEmpty else { continue }
            // Fast rap on a quiet mic (Nate 2026-10-13, E1): the live recognizer leaves fragments and Whisper
            // gives nothing back on most of them. Then the take's own transcription stands in for those
            // lines, cut at its commas below (one long line here; recutAtCommas spreads it over the take).
            let unfixed = inTake.filter { $0.fixed == nil }.count
            let short = inTake.map { $0.text.split(whereSeparator: \.isWhitespace).count }.sorted()
            let fragments = short[short.count / 2] <= 3
            if unfixed * 2 >= inTake.count, fragments {
                let text = lyr.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let ws = text.split(whereSeparator: \.isWhitespace).map(String.init), step = t.durationSeconds / Double(max(1, ws.count))
                pouredSlots.append([LabSession.Version(id: "\(t.id)#pour", takeID: t.id, text: text, start: 0, end: t.durationSeconds, at: t.sessionStartSeconds,
                                                       words: ws.enumerated().map { LabSession.Word(w: $1, start: Double($0) * step, end: Double($0 + 1) * step) },
                                                       chords: chords(t, 0, t.durationSeconds), keeper: false)])
                poured.insert(t.id); replacedLive.formUnion(inTake.map(\.at))
                continue
            }
            // Lines that get their own Whisper pass: the whole-take transcription stays out (it collapses
            // repeats, so pouring it misplaces words: 2026-10-12 loop test). Live lines show as sung.
            if liveTakesSelfFix { poured.insert(t.id); continue }
            let sung = lyr.words.isEmpty ? lyr.text.split(whereSeparator: \.isWhitespace).map(String.init) : lyr.words.map(\.text)
            let split = LabSessionExport.pourSplit(sung.filter { !$0.isEmpty }, into: inTake.map { $0.text.split(whereSeparator: \.isWhitespace).map(String.init) })
            let lines = split.lines
            var placed = inTake
            // Words past the last live line: their own lines, spread over the rest of the take.
            let extra = LabSessionExport.chunk(split.overflow), after = (inTake.last?.end ?? t.sessionStartSeconds)
            let room = max(0.5, t.sessionStartSeconds + t.durationSeconds - after) / Double(max(1, extra.count))
            for (k, ws) in extra.enumerated() {
                placed.append(LiveLine(text: ws.joined(separator: " "), at: after + Double(k) * room, end: after + Double(k + 1) * room))
            }
            for (i, l) in placed.enumerated() {
                let lineWords = i < lines.count ? lines[i] : []
                let text = lineWords.isEmpty ? l.text : lineWords.joined(separator: " ")
                let start = max(0, l.at - t.sessionStartSeconds), dur = max(0.3, l.end - l.at)
                let ws = text.split(whereSeparator: \.isWhitespace).map(String.init), step = dur / Double(max(1, ws.count))
                pouredSlots.append([LabSession.Version(
                    id: "\(t.id)#live\(i)", takeID: t.id, text: text, start: start, end: start + dur, at: l.at,
                    words: ws.enumerated().map { LabSession.Word(w: $1, start: Double($0) * step, end: Double($0 + 1) * step) },
                    chords: chords(t, start, start + dur), keeper: false)])
            }
            poured.insert(t.id)
        }
        slots = slots.map { $0.filter { !poured.contains($0.takeID) } }.filter { !$0.isEmpty } + pouredSlots

        // Live lines (what you saw while singing) stay unless a take's real transcription covers them:
        // a take with any real lyric lines owns its whole stretch of the session.
        let covered: [ClosedRange<Double>] = takes.compactMap { t in
            let real = slots.contains { $0.contains { $0.takeID == t.id } }
            return real ? (t.sessionStartSeconds - 0.3)...(t.sessionStartSeconds + t.durationSeconds + 0.3) : nil
        }
        var livePart: [[LabSession.Version]] = []
        for (n, line) in liveRaw.enumerated() where !LiveLines.isJunk(line.shown) {
            let mid = (line.at + line.end) / 2
            if line.fixed == nil, covered.contains(where: { $0.contains(mid) }) { continue }
            if replacedLive.contains(line.at) { continue }
            let shown = adLibCommas(lowercaseStart(keepProtected(line, protected: protected))) + ((line.cut ?? false) ? " ⏹" : "")      // Stop pressed mid-line: a stop mark
            let words = shown.split(whereSeparator: \.isWhitespace).map(String.init)
            let dur = max(0.3, line.end - line.at), step = dur / Double(max(1, words.count))
            let timed = words.enumerated().map { i, w in LabSession.Word(w: w, start: Double(i) * step, end: Double(i + 1) * step) }
            // The chords under the line come from the take that was playing while you sang it.
            let under = takes.first { $0.kind == "playing" && $0.sessionStartSeconds - 0.3 <= mid && mid <= $0.sessionStartSeconds + $0.durationSeconds + 0.3 && !($0.chords ?? []).isEmpty }
            let lineChords = under.map { chords($0, line.at - $0.sessionStartSeconds, line.end - $0.sessionStartSeconds) } ?? []
            // Typed lines stay exactly as typed: never joined, recut or folded (takeID "typed").
            livePart.append([LabSession.Version(id: "live-\(n)", takeID: line.typed == true ? "typed" : "", text: line.typed == true ? line.text : shown, start: 0, end: dur,
                                                at: line.at, words: timed, chords: lineChords, keeper: false)])
        }
        slots = (slots + livePart).sorted { ($0.first?.at ?? 0) < ($1.first?.at ?? 0) }
        slots = LabSessionExport.foldLoneWords(slots)
        slots = joinContinuations(slots)
        slots = recutAtCommas(slots)
        slots = dropFalseStarts(slots)
        slots = collapseRepeats(slots)
        slots = RetakeAligner.align(slots)
        slots = LabSessionExport.groupVersions(slots)
        slots = RetakeAligner.joinFragments(slots)
        // The last word on every line: no trailing comma or period, and the line starts lowercase.
        return slots.map { $0.map { v in
            LabSession.Version(id: v.id, takeID: v.takeID, text: lowercaseStart(trimLineEnd(v.text)), start: v.start, end: v.end,
                               at: v.at, words: v.words, chords: v.chords, keeper: v.keeper)
        } }
    }
}
