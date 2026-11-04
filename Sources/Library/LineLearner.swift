import Foundation

/// Learns from what you do, on this Mac: a small logistic regression over a line's features, trained a
/// little on every correction. It only moves a verdict when it is sure, so with nothing learned it does
/// nothing and today's behaviour stands.
public struct LineLearner: Codable, Equatable, Sendable {
    public struct Example: Codable, Equatable, Sendable {
        var x: [Int: Double]
        var talk: Bool
        var lean: Double
        var weight: Double
    }
    /// Feature → weight, and the running squared gradients (AdaGrad: rare words learn fast, common ones settle).
    public private(set) var weights: [Int: Double] = [:]
    private var squares: [Int: Double] = [:]
    /// Your corrections so far. A click on a line counts 1, a star or an edit counts less.
    public private(set) var corrections = 0
    /// The last corrections to a line where the learner and the verdict it would move disagreed: true = the learner was right.
    public private(set) var duels: [Bool] = []
    /// Recent examples, replayed on each correction (hashed words and numbers only, no text).
    private var memory: [Example] = []

    static let minKnownWords = 2, rate = 0.3, decay = 1e-4, replayRounds = 3, memoryLimit = 300, leanLimit = 3.0

    public init() {}

    /// The verdict's lean as log odds of talk: `p` is how sure the base is of talk.
    public static func lean(talkProbability p: Double) -> Double {
        let q = min(0.98, max(0.02, p))
        return log(q / (1 - q))
    }

    public func score(_ x: [Int: Double]) -> Double { x.reduce(0) { $0 + (weights[$1.key] ?? 0) * $1.value } }

    /// How likely this line is talk, given what the base thinks.
    func talkProbability(_ x: [Int: Double], lean: Double) -> Double {
        1 / (1 + exp(-(score(x) + lean)))
    }

    /// Whether the guard lets it speak: enough corrections, and not losing to the verdicts it would override.
    public var isTrusted: Bool {
        corrections >= LineJudgeConfig.minCorrections && duels.filter { $0 }.count * 2 >= duels.count
    }

    /// Its say on a line, as log odds of talk: 0 unless it is trusted, sure, and knows some of the line's
    /// words. The measured features alone never move a line: every correction is a line the base got wrong,
    /// so with no words to go on they would only push everything one way.
    public func evidence(_ x: [Int: Double]) -> Double {
        guard isTrusted, x.keys.filter({ $0 >= LineFeatures.wordBase && weights[$0] != nil }).count >= Self.minKnownWords else { return 0 }
        let s = score(x)
        return abs(s) >= Self.lean(talkProbability: LineJudgeConfig.overrideConfidence) ? s : 0
    }

    /// Where the rules decided (no model): the learner's answer when it is sure of the other one.
    public func override(_ verdict: LineVerdict, features x: [Int: Double]) -> LineVerdict? {
        let e = evidence(x)
        if verdict != .writing, e < 0 { return .writing }
        if verdict == .writing, e > 0 { return .talk }
        return nil
    }

    /// One correction: this line is `talk`, or is a lyric. `was` is what the app had decided; `weight` from
    /// LineJudgeConfig. `neighbours` are lines around it you left alone, a light vote for what they show.
    public mutating func correct(_ x: [Int: Double], talk: Bool, lean: Double, was: LineJudge.Decision? = nil, weight: Double = 1,
                                 neighbours: [(x: [Int: Double], talk: Bool, lean: Double)] = []) {
        if let was {
            if was.source == .learner, (was.verdict != .writing) != talk { record(duel: false) }
            else if was.source != .learner, (was.verdict != .writing) != talk,
                    (talkProbability(x, lean: lean) >= 0.5) == talk { record(duel: true) }
        }
        corrections += 1
        memory.append(Example(x: x, talk: talk, lean: lean, weight: weight))
        for n in neighbours { memory.append(Example(x: n.x, talk: n.talk, lean: n.lean, weight: weight * Self.neighbourWeight)) }
        if memory.count > Self.memoryLimit { memory.removeFirst(memory.count - Self.memoryLimit) }
        // A fixed replay order (newest first), so the same corrections always make the same learner.
        for _ in 0..<Self.replayRounds { for e in memory.reversed() { step(e) } }
        trim()
    }

    static let neighbourWeight = 0.15

    private mutating func record(duel: Bool) {
        duels.append(duel)
        if duels.count > LineJudgeConfig.guardWindow { duels.removeFirst(duels.count - LineJudgeConfig.guardWindow) }
    }

    private mutating func step(_ e: Example) {
        let p = 1 / (1 + exp(-(score(e.x) + e.lean)))
        let y = e.talk ? 1.0 : 0.0
        for (k, v) in e.x {
            let w = weights[k] ?? 0
            let g = e.weight * ((p - y) * v + Self.decay * w)
            let s = (squares[k] ?? 0) + g * g
            squares[k] = s
            weights[k] = w - Self.rate * g / (s + 1e-8).squareRoot()
        }
    }

    /// Keeps the file small: weights that round to nothing go.
    private mutating func trim() {
        for (k, w) in weights where abs(w) < 1e-3 { weights[k] = nil; squares[k] = nil }
    }
}

/// The per-user file at the top of the Hot Mic folder (`line-judge.json`): the two switches and what the
/// learner has learned. Never leaves the Mac; deleting it starts over.
public struct LineJudgeProfile: Codable, Equatable, Sendable {
    public var modelOn = true
    public var learnerOn = true
    public var learner = LineLearner()
    public init() {}

    public static let fileName = "line-judge.json"

    /// The Hot Mic folder a session folder sits in (`<root>/Sessions/<session>`).
    public static func url(forSession folder: URL) -> URL {
        folder.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(fileName)
    }

    /// Display-only fallback; it is never used as the starting point of a mutation.
    public static func read(_ url: URL) -> LineJudgeProfile {
        (try? readChecked(url)) ?? LineJudgeProfile()
    }

    public static func readChecked(_ url: URL) throws -> LineJudgeProfile {
        try PersistenceFile.read(url, default: LineJudgeProfile())
    }

    /// Compatibility wrapper: on failure, logs and returns persisted state, never the unsaved update.
    @discardableResult
    public static func update(at url: URL, _ change: (inout LineJudgeProfile) -> Void) -> LineJudgeProfile {
        do { return try updateChecked(at: url, change) } catch { return read(url) }
    }

    @discardableResult
    public static func updateChecked(at url: URL, _ change: (inout LineJudgeProfile) -> Void) throws -> LineJudgeProfile {
        JudgePersistence.lock.lock(); defer { JudgePersistence.lock.unlock() }
        var profile = try readChecked(url)
        change(&profile)
        try profile.writeChecked(to: url)
        return profile
    }

    @discardableResult
    public func write(to url: URL) -> Bool {
        do { try writeChecked(to: url); return true } catch { return false }
    }

    public func writeChecked(to url: URL) throws {
        JudgePersistence.lock.lock(); defer { JudgePersistence.lock.unlock() }
        _ = try Self.readChecked(url)
        try PersistenceFile.write(self, to: url)
    }
}
