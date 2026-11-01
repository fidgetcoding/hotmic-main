import Foundation

/// Proof that the learner learns: simulated corrections on some sessions, measured on a session it never
/// saw. The simulated you fixes up to `budget` wrong lines per session (in a fixed shuffled order), and
/// leaves the rest alone. Truth files come from outside the app (`bench/lines.py`, or a test fixture).
public enum JudgeReplay {
    public struct Row: Codable, Equatable, Sendable { public var id: String; public var verdict: String; public var source: String
        public init(id: String, verdict: String, source: String) { self.id = id; self.verdict = verdict; self.source = source } }

    /// One line's true label: "talk", "writing", or anything else (playback, beat…) that isn't scored.
    public struct Truth: Codable, Equatable, Sendable { public var id: String; public var truth: String; public var unsure: Bool? }

    /// Talk lines hidden and writing lines kept, against the truth.
    public struct Score: Codable, Equatable, Sendable {
        public var talkHidden = 0, writingHidden = 0, talk = 0, writing = 0
        public init() {}
        public var precision: Double { Double(talkHidden) / Double(max(1, talkHidden + writingHidden)) }
        public var recall: Double { Double(talkHidden) / Double(max(1, talk)) }
        public var writingKept: Double { Double(writing - writingHidden) / Double(max(1, writing)) }
        mutating func add(_ o: Score) { talkHidden += o.talkHidden; writingHidden += o.writingHidden; talk += o.talk; writing += o.writing }
    }

    public struct Result: Codable, Equatable, Sendable {
        public var session: String
        public var base: Score, learned: Score
        public var flips: Int, corrections: Int
    }
    public struct Report: Codable, Equatable, Sendable {
        /// Each session judged by a learner taught on the others.
        public var leaveOneOut: [Result] = []
        /// Each ordered pair: taught on A only, measured on B.
        public var pairs: [Result] = []
        /// Each session: taught on its first half, measured on its second half.
        public var within: [Result] = []
    }

    public struct Session {
        public var name: String
        public var rows: [SungRow]
        public var stored: SessionJudgments
        public var truth: [String: Bool]     // id → is talk; lines not scored are absent
        public var audio: [String: LineAudio]
        public init(name: String, rows: [SungRow], stored: SessionJudgments, truth: [String: Bool], audio: [String: LineAudio] = [:]) {
            self.name = name; self.rows = rows; self.stored = stored; self.truth = truth; self.audio = audio
        }
    }

    public static func run(sessions: [(folder: URL, truth: URL)], budget: Int) throws -> Report {
        evaluate(try load(sessions), budget: budget)
    }

    public static func load(_ sessions: [(folder: URL, truth: URL)]) throws -> [Session] {
        try sessions.map { folder, truthFile -> Session in
            let lines = try String(contentsOf: truthFile, encoding: .utf8).split(whereSeparator: \.isNewline)
            var truth: [String: Bool] = [:]
            for line in lines {
                let t = try JSONDecoder().decode(Truth.self, from: Data(line.utf8))
                if t.unsure != true, t.truth == "talk" || t.truth == "writing" { truth[t.id] = t.truth == "talk" }
            }
            return Session(name: folder.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, rows: SessionJudge.rows(folder: folder),
                           stored: SessionJudgments.read(folder), truth: truth, audio: LineAudioCache.read(folder))
        }
    }

    public static func evaluate(_ sessions: [Session], budget: Int) -> Report {
        var report = Report()
        for (i, test) in sessions.enumerated() {
            var learner = LineLearner()
            for (j, s) in sessions.enumerated() where j != i { teach(&learner, from: s, budget: budget) }
            report.leaveOneOut.append(result(test, learner: learner))
            for (j, a) in sessions.enumerated() where j != i {
                var one = LineLearner()
                teach(&one, from: a, budget: budget)
                var r = result(test, learner: one)
                r.session = "\(a.name) → \(test.name)"
                report.pairs.append(r)
            }
            let half = test.rows.count / 2
            var early = test, late = test
            early.rows = Array(test.rows[..<half]); late.rows = Array(test.rows[half...])
            var own = LineLearner()
            teach(&own, from: early, budget: budget)
            report.within.append(result(late, learner: own))
        }
        return report
    }

    /// The simulated you: goes through the session's wrong lines and fixes up to `budget`.
    public static func teach(_ learner: inout LineLearner, from s: Session, budget: Int) {
        let input = LineJudge.learningInput(s.rows, stored: s.stored, audio: s.audio)
        let decisions = LineJudge.decide(s.rows, stored: s.stored, useModel: true, audio: s.audio)
        let shown = { (id: String) in decisions[id].map { $0.verdict != .writing && $0.source != .rules } ?? false }
        var wrong = s.rows.indices.filter { i in s.truth[s.rows[i].id].map { $0 != shown(s.rows[i].id) } ?? false }
        // A fixed shuffle: the same run gives the same numbers.
        var seed: UInt64 = 2_654_435_769
        for k in stride(from: wrong.count - 1, to: 0, by: -1) {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            wrong.swapAt(k, Int((seed >> 33) % UInt64(k + 1)))
        }
        for i in wrong.prefix(budget) {
            let id = s.rows[i].id
            guard let line = input[id], let talk = s.truth[id] else { continue }
            var neighbours: [(x: [Int: Double], talk: Bool, lean: Double)] = []
            for j in [i - 2, i - 1, i + 1, i + 2] where s.rows.indices.contains(j) {
                if let n = input[s.rows[j].id] { neighbours.append((n.x, shown(s.rows[j].id), n.lean)) }
            }
            learner.correct(line.x, talk: talk, lean: line.lean, was: decisions[id], weight: 1, neighbours: neighbours)
        }
    }

    static func result(_ s: Session, learner: LineLearner) -> Result {
        let base = LineJudge.decide(s.rows, stored: s.stored, useModel: true, audio: s.audio)
        let learned = LineJudge.decide(s.rows, stored: s.stored, learner: learner, useModel: true, audio: s.audio)
        let flips = s.rows.filter { base[$0.id]?.verdict != learned[$0.id]?.verdict }.count
        return Result(session: s.name, base: score(s, base), learned: score(s, learned), flips: flips, corrections: learner.corrections)
    }

    static func score(_ s: Session, _ decisions: [String: LineJudge.Decision]) -> Score {
        var out = Score()
        for row in s.rows {
            guard let talk = s.truth[row.id], let d = decisions[row.id] else { continue }
            let hidden = d.verdict != .writing && d.source != .rules
            if talk { out.talk += 1; if hidden { out.talkHidden += 1 } } else { out.writing += 1; if hidden { out.writingHidden += 1 } }
        }
        return out
    }
}
