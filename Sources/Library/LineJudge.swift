import Foundation

/// What a line of the session is. A judge only sorts and hides; it never changes or suggests a word.
public enum LineVerdict: String, Codable, Equatable, Sendable {
    case writing, talk, playback
}

/// Who decided a line's verdict, weakest first.
public enum LineJudgeSource: String, Codable, Equatable, Sendable {
    case rules, model, learner, you
}

/// One line as a judge sees it, in the order it was sung.
public struct SungRow: Equatable, Sendable {
    public var id: String
    public var takeID: String
    public var text: String
    /// Session seconds. Whisper's word times can collapse, so this can be off by a whole decode window.
    public var at: Double
    public var duration: Double
    /// The take's kind ("singing", "rap", "playing", …).
    public var kind: String?

    public init(id: String, takeID: String, text: String, at: Double, duration: Double, kind: String? = nil) {
        self.id = id; self.takeID = takeID; self.text = text; self.at = at; self.duration = duration; self.kind = kind
    }
}

/// Every threshold of the judge in one place.
public enum LineJudgeConfig {
    /// The learner has a say on a line only when its own score is this sure. Measured on the livestream test
    /// corpus: 0.85 hid more lyrics than the model alone, 0.98 kept more lyrics and caught more talk.
    public static let overrideConfidence = 0.98
    /// …and only after this many corrections from you.
    public static let minCorrections = 12
    /// …and only while it has been right at least as often as what it would override, on your last corrections.
    public static let guardWindow = 40
    /// How sure the model's or the rules' verdict counts as before the learner has learned anything.
    public static let baseLean = 0.75
    /// Seconds for one line, and for a whole pass, before the rest falls back to the rules.
    public static let modelLineTimeout = 8.0
    public static let modelPassTimeout = 1_800.0
    /// Hard failures in a row (not refusals) that end a model pass.
    public static let maxFailuresInARow = 5
    /// Lines of context the model reads on each side of the line.
    public static let contextBefore = 3, contextAfter = 2
    /// How much a signal counts against a click on the line itself (1).
    public static let weightStar = 0.5, weightEdit = 0.5, weightDelete = 0.5
}

/// Today's rules, unchanged: the chatter list and the take's kind. What runs when the model can't.
public enum LineRules {
    public static func verdict(_ row: SungRow) -> LineVerdict {
        if row.kind == "talk" || WholeSong.isChatter(row.text) { return .talk }
        return .writing
    }
}

/// A local model that reads one line with the lines around it.
public protocol LineModel: Sendable {
    /// Short name stored with the session ("apple-foundation").
    var name: String { get }
    var isAvailable: Bool { get }
    /// nil = it refused, or gave no usable answer. Throwing means the model itself failed.
    func judge(before: [String], line: String, after: [String]) async throws -> LineVerdict?
}

/// Serializes judge/profile read-modify-write transactions within the app. Recursive because a
/// learning transaction also writes its profile and session judgments.
enum JudgePersistence {
    static let lock = NSRecursiveLock()
}

/// The judged lines of one session (`line-judgments.json` beside the takes). The raw logs (take sidecars,
/// live-lines.json) are never touched, so the pass can be re-run or thrown away at any time.
public struct SessionJudgments: Codable, Equatable, Sendable {
    public struct Line: Codable, Equatable, Sendable {
        /// The words this answer was for. A line whose words changed (a late Whisper fix) is judged again.
        public var text: String
        public var model: LineVerdict?
    }
    public struct Stats: Codable, Equatable, Sendable {
        public var lines = 0, answered = 0, refused = 0, timedOut = 0, failed = 0
        public var seconds = 0.0
        public init() {}
    }
    /// The model that answered, nil when none did.
    public var engine: String?
    public var lines: [String: Line] = [:]
    /// Your corrections for this session (line id → verdict). Always win, survive every re-run.
    public var corrections: [String: LineVerdict] = [:]
    public var stats = Stats()
    public init() {}

    public static let fileName = "line-judgments.json"

    /// Display-only fallback; checked reads distinguish absent files from damaged data.
    public static func read(_ folder: URL) -> SessionJudgments {
        (try? readChecked(folder)) ?? SessionJudgments()
    }

    public static func readChecked(_ folder: URL) throws -> SessionJudgments {
        try PersistenceFile.read(folder.appendingPathComponent(fileName), default: SessionJudgments())
    }

    @discardableResult
    public func write(to folder: URL) -> Bool {
        do { try writeChecked(to: folder); return true } catch { return false }
    }

    public func writeChecked(to folder: URL) throws {
        JudgePersistence.lock.lock(); defer { JudgePersistence.lock.unlock() }
        _ = try Self.readChecked(folder) // direct writes must also preserve an unreadable existing file
        try PersistenceFile.write(self, to: folder.appendingPathComponent(Self.fileName), pretty: true)
    }

    /// Model checkpoints own model answers; the latest readable user corrections always win.
    @discardableResult
    func saveModelProgress(to folder: URL) throws -> SessionJudgments {
        JudgePersistence.lock.lock(); defer { JudgePersistence.lock.unlock() }
        var merged = self
        merged.corrections.merge(try Self.readChecked(folder).corrections) { _, latest in latest }
        try merged.writeChecked(to: folder)
        return merged
    }

}

/// A line the judge took out of the notepad: still there, one click brings it back.
public struct JudgedAside: Encodable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var at: Double
    public var verdict: LineVerdict
    public var source: LineJudgeSource
}

/// What the window shows about the judge for one session.
public struct SessionJudgeSummary: Encodable, Equatable, Sendable {
    /// A model judged this session (the sidebar's mark).
    public var model: String?
    public var aside: [JudgedAside] = []
    public init(model: String? = nil, aside: [JudgedAside] = []) { self.model = model; self.aside = aside }
}

/// Talk and writing come in stretches. A two-state model over the session's lines: each line's evidence
/// for talk (log odds), and a price for changing state.
public enum LineSmoother {
    /// How far one model answer counts, and how likely the next line stays in the same state. Tuned on
    /// the livestream test corpus; your own clicks stay out of it, so a click moves that line and no other.
    public static let modelEvidence = log(0.7 / 0.3), stay = 0.95

    public struct State: Equatable, Sendable {
        public var talk: Bool
        /// Probability of talk given every line.
        public var probability: Double
    }

    public static func run(evidence: [Double]) -> [State] {
        let n = evidence.count
        guard n > 0 else { return [] }
        let keep = log(stay), change = log(1 - stay)
        // Most likely path (Viterbi).
        var best = [evidence[0] / 2, -evidence[0] / 2]      // [talk, writing]
        var from = [[Int]](repeating: [0, 1], count: n)
        for i in 1..<max(1, n) {
            let e = [evidence[i] / 2, -evidence[i] / 2]
            var next = [0.0, 0.0]
            for s in 0...1 {
                let same = best[s] + keep, other = best[1 - s] + change
                from[i][s] = same >= other ? s : 1 - s
                next[s] = max(same, other) + e[s]
            }
            best = next
        }
        var state = best[0] >= best[1] ? 0 : 1
        var path = [Int](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) { path[i] = state; state = from[i][state] }
        // How sure, line by line (forward-backward).
        func likelihood(_ e: Double) -> [Double] { [exp(e / 2), exp(-e / 2)] }
        var forward = [[Double]](repeating: [0.5, 0.5], count: n), backward = [[Double]](repeating: [1, 1], count: n)
        for i in 0..<n {
            let p = i > 0 ? forward[i - 1] : [0.5, 0.5], l = likelihood(evidence[i])
            let a = (p[0] * stay + p[1] * (1 - stay)) * l[0], b = (p[1] * stay + p[0] * (1 - stay)) * l[1]
            forward[i] = [a / (a + b), b / (a + b)]
        }
        if n > 1 {
            for i in stride(from: n - 2, through: 0, by: -1) {
                let l = likelihood(evidence[i + 1]), b = backward[i + 1]
                let x = stay * l[0] * b[0] + (1 - stay) * l[1] * b[1], y = stay * l[1] * b[1] + (1 - stay) * l[0] * b[0]
                backward[i] = [x / (x + y), y / (x + y)]
            }
        }
        return (0..<n).map { i in
            let a = forward[i][0] * backward[i][0], b = forward[i][1] * backward[i][1]
            return State(talk: path[i] == 0, probability: a / (a + b))
        }
    }
}

public enum LineJudge {
    /// Every sung version, in the order it was sung: by take, then by its place in the take. The notepad's
    /// slots group versions across the whole session, which scrambles the conversation a judge must read.
    public static func rows(slots: [[LabSession.Version]], takes: [TakeRecord]) -> [SungRow] {
        let kind = Dictionary(takes.map { ($0.id, ($0.kind, $0.sessionStartSeconds)) }, uniquingKeysWith: { a, _ in a })
        let versions = slots.flatMap { $0 }.filter { isJudged($0) }
        let order = { (v: LabSession.Version) -> (Double, Int, Double) in
            (kind[v.takeID]?.1 ?? v.at, placeInTake(v.id), v.at)
        }
        return versions.sorted { order($0) < order($1) }.map {
            SungRow(id: $0.id, takeID: $0.takeID, text: $0.text, at: $0.at, duration: max(0, $0.end - $0.start), kind: kind[$0.takeID]?.0)
        }
    }

    /// Words with audio behind them: not typed lines, hums, beatbox or chord rows.
    static func isJudged(_ v: LabSession.Version) -> Bool {
        !v.text.trimmingCharacters(in: .whitespaces).isEmpty && v.takeID != "typed"
            && !["hum-", "beat-", "chords-"].contains { v.id.hasPrefix($0) }
    }

    /// "<take>#12" and "<take>#12#c1" → 12; live lines have no number and sort by time.
    static func placeInTake(_ id: String) -> Int {
        let parts = id.split(separator: "#")
        return parts.count > 1 ? Int(parts[1]) ?? 0 : 0
    }

    public struct Decision: Equatable, Sendable {
        public var verdict: LineVerdict
        public var source: LineJudgeSource
    }

    /// One verdict per row: your correction, else the model where it answered, smoothed over the session
    /// (talk and writing come in stretches, and one odd answer inside a stretch is usually the model's
    /// mistake), else today's rules. The learner adds its say to a line's evidence only when it is sure
    /// (see `LineLearner.evidence`), so a stretch it recognizes moves as a stretch.
    public static func decide(_ rows: [SungRow], stored: SessionJudgments, learner: LineLearner? = nil,
                              useModel: Bool = true, audio: [String: LineAudio] = [:]) -> [String: Decision] {
        let context = LineFeatures.Context(rows)
        let base = baseline(rows, stored: stored, useModel: useModel)
        let features = learner == nil ? [] : rows.indices.map { LineFeatures.make(rows[$0], context: context, audio: audio[rows[$0].id]) }
        let told = learner.map { l in features.map { l.evidence($0) } } ?? []
        let learned = told.contains { $0 != 0 } && base.smooth != nil
            ? LineSmoother.run(evidence: rows.indices.map { base.evidence[$0] + told[$0] }) : nil
        var out: [String: Decision] = [:]
        for (i, row) in rows.enumerated() {
            if let yours = stored.corrections[row.id] { out[row.id] = Decision(verdict: yours, source: .you); continue }
            guard base.answers[i] != nil, let smooth = base.smooth else {
                // No answer from the model: today's rules, which only a sure learner may move.
                let rule = LineRules.verdict(row)
                let flipped = told.isEmpty || told[i] == 0 ? nil : learner?.override(rule, features: features[i])
                out[row.id] = flipped.map { Decision(verdict: $0, source: .learner) } ?? Decision(verdict: rule, source: .rules)
                continue
            }
            let talk = learned?[i].talk ?? smooth[i].talk
            out[row.id] = Decision(verdict: talk ? .talk : .writing, source: talk != smooth[i].talk ? .learner : .model)
        }
        return out
    }

    /// The model's answers (for these exact words) and what they say once smoothed; nil when it never answered.
    static func baseline(_ rows: [SungRow], stored: SessionJudgments, useModel: Bool) -> (answers: [LineVerdict?], evidence: [Double], smooth: [LineSmoother.State]?) {
        let answers: [LineVerdict?] = rows.map { row in
            guard useModel, let line = stored.lines[row.id], line.text == row.text else { return nil }
            return line.model
        }
        let evidence = answers.map { a in a.map { ($0 != .writing ? 1 : -1) * LineSmoother.modelEvidence } ?? 0 }
        return (answers, evidence, answers.contains { $0 != nil } ? LineSmoother.run(evidence: evidence) : nil)
    }

    /// What the learner gets for a line: its features and how the base leans.
    public static func learningInput(_ rows: [SungRow], stored: SessionJudgments, useModel: Bool = true, audio: [String: LineAudio] = [:])
        -> [String: (x: [Int: Double], lean: Double)] {
        let context = LineFeatures.Context(rows)
        let base = baseline(rows, stored: stored, useModel: useModel)
        var out: [String: (x: [Int: Double], lean: Double)] = [:]
        for (i, row) in rows.enumerated() {
            let rule = LineRules.verdict(row) != .writing ? LineJudgeConfig.baseLean : 1 - LineJudgeConfig.baseLean
            let p = base.answers[i] != nil ? base.smooth?[i].probability ?? rule : rule
            out[row.id] = (LineFeatures.make(row, context: context, audio: audio[row.id]), LineLearner.lean(talkProbability: p))
        }
        return out
    }

    /// The notepad after judging: versions judged talk or playback leave it (by the model, the learner or
    /// you; the rules alone never hide a line, as today), lines with nothing left go.
    public static func apply(_ slots: [[LabSession.Version]], decisions: [String: Decision], stored: SessionJudgments)
        -> (slots: [[LabSession.Version]], aside: [JudgedAside]) {
        var aside: [JudgedAside] = []
        let kept = slots.map { slot in
            slot.filter { v in
                guard isJudged(v), let d = decisions[v.id], d.verdict != .writing, d.source != .rules else { return true }
                aside.append(JudgedAside(id: v.id, text: v.text, at: v.at, verdict: d.verdict, source: d.source))
                return false
            }
        }.filter { !$0.isEmpty }
        return (kept, aside.sorted { $0.at < $1.at })
    }
}
