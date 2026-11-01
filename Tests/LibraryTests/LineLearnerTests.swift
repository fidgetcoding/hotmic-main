import XCTest
@testable import Library

/// Synthetic sessions: invented talk and invented lyrics, so these prove the mechanism without any real data.
final class LineLearnerTests: XCTestCase {
    private func x(_ words: String) -> [Int: Double] {
        let row = SungRow(id: "a", takeID: "t", text: words, at: 0, duration: 0)
        return LineFeatures.make(row, context: LineFeatures.Context([row]), audio: nil)
    }
    private let neutral = LineLearner.lean(talkProbability: 0.5)

    private func taught(_ n: Int) -> LineLearner {
        var l = LineLearner()
        for i in 0..<n {
            l.correct(x("everybody vote in the chat \(i)"), talk: true, lean: neutral)
            l.correct(x("velvet rain on my window pane \(i)"), talk: false, lean: neutral)
        }
        return l
    }

    func testANewLearnerNeverOverrides() {
        XCTAssertNil(LineLearner().override(.writing, features: x("everybody vote in the chat")))
        XCTAssertNil(LineLearner().override(.talk, features: x("velvet rain on my window pane")))
    }

    func testItWaitsForEnoughCorrections() {
        let few = taught(LineJudgeConfig.minCorrections / 2 - 1)
        XCTAssertLessThan(few.corrections, LineJudgeConfig.minCorrections)
        XCTAssertNil(few.override(.writing, features: x("everybody vote in the chat")))
    }

    func testOnceTaughtItMovesTheLinesItIsSureOf() {
        let l = taught(LineJudgeConfig.minCorrections)
        XCTAssertEqual(l.override(.writing, features: x("everybody vote in the chat")), .talk)
        XCTAssertEqual(l.override(.talk, features: x("velvet rain on my window pane")), .writing)
        XCTAssertNil(l.override(.writing, features: x("velvet rain on my window pane")), "already agrees")
    }

    func testUnknownWordsChangeNothing() {
        XCTAssertNil(taught(LineJudgeConfig.minCorrections).override(.writing, features: x("zebra quartz mango")))
    }

    func testTheGuardStopsALearnerThatKeepsLosing() {
        var l = taught(LineJudgeConfig.minCorrections)
        let line = x("everybody vote in the chat")
        XCTAssertEqual(l.override(.writing, features: line), .talk)
        // You keep correcting lines the learner moved: it was wrong each time, so it stands down.
        for i in 0..<4 {
            l.correct(x("once more with feeling \(i)"), talk: false, lean: neutral, was: .init(verdict: .talk, source: .learner))
        }
        XCTAssertFalse(l.duels.isEmpty)
        XCTAssertNil(l.override(.writing, features: line))
    }

    func testSameCorrectionsMakeTheSameLearner() {
        let a = taught(6).weights, b = taught(6).weights
        XCTAssertEqual(a.count, b.count)
        for (k, v) in a { XCTAssertEqual(v, b[k] ?? .nan, accuracy: 1e-9) }
    }

    func testBucketsAreStableAcrossRuns() {
        XCTAssertEqual(LineFeatures.bucket("a"), Int(UInt32(3_826_002_220)) % LineFeatures.wordBuckets, "FNV-1a of a known string")
        XCTAssertNotEqual(LineFeatures.bucket("moonlight"), LineFeatures.bucket("sunlight"))
    }

    func testTheFileStaysSmallAndHoldsNoWords() throws {
        var profile = LineJudgeProfile()
        for i in 0..<200 { profile.learner.correct(x("velvet rain number \(i) on my secretword window"), talk: i % 2 == 0, lean: neutral) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        profile.write(to: url)
        let data = try Data(contentsOf: url)
        XCTAssertLessThan(data.count, 1_000_000, "small")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secretword"))
        XCTAssertEqual(LineJudgeProfile.read(url), profile)
    }

    func testADamagedFileStartsOver() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(LineJudgeProfile.read(url), LineJudgeProfile())
    }

    // MARK: - Replay: corrections on session A improve verdicts on session B

    private static let talkWords = ["everybody", "vote", "chat", "stream", "subscribe", "tomorrow", "question", "sound", "volume", "follow"]
    private static let lyricWords = ["velvet", "rain", "window", "midnight", "ember", "silver", "river", "shadow", "ocean", "crown"]

    /// A session of stretches: talk, then lyrics, then talk. The model calls a stretch of talk "lyrics" (a
    /// mistake the learner can fix by its vocabulary), and is otherwise right.
    private func session(_ name: String, seed: Int) -> JudgeReplay.Session {
        var rows: [SungRow] = [], truth: [String: Bool] = [:], stored = SessionJudgments()
        func add(_ words: [String], talk: Bool, modelSays: LineVerdict) {
            let n = rows.count
            let text = (0..<5).map { words[($0 * 3 + n + seed) % words.count] }.joined(separator: " ")
            let row = SungRow(id: "\(name)#\(n)", takeID: name, text: text, at: Double(n) * 3, duration: 3, kind: "rap")
            rows.append(row)
            truth[row.id] = talk
            stored.lines[row.id] = .init(text: text, model: modelSays)
        }
        for _ in 0..<20 { add(Self.talkWords, talk: true, modelSays: .talk) }
        for _ in 0..<20 { add(Self.talkWords, talk: true, modelSays: .writing) }       // the stretch the model gets wrong
        for _ in 0..<20 { add(Self.lyricWords, talk: false, modelSays: .writing) }
        stored.engine = "stub"
        return JudgeReplay.Session(name: name, rows: rows, stored: stored, truth: truth)
    }

    func testCorrectionsOnOneSessionImproveTheNext() {
        let a = session("a", seed: 1), b = session("b", seed: 7)
        var learner = LineLearner()
        JudgeReplay.teach(&learner, from: a, budget: 20)
        XCTAssertGreaterThanOrEqual(learner.corrections, LineJudgeConfig.minCorrections)
        let result = JudgeReplay.result(b, learner: learner)
        XCTAssertGreaterThan(result.learned.recall, result.base.recall + 0.2, "more of B's talk is caught")
        XCTAssertGreaterThanOrEqual(result.learned.writingKept, result.base.writingKept, "and none of its lyrics are lost")
    }

    func testNeverWorseWhenThereIsNothingToLearnFrom() {
        // Sessions with different vocabularies: A teaches nothing that applies to B, so B must not change.
        let a = session("a", seed: 1)
        var b = session("b", seed: 7)
        b.rows = b.rows.map { var r = $0; r.text = r.text.split(separator: " ").map { "x" + $0 }.joined(separator: " "); return r }
        for r in b.rows { b.stored.lines[r.id]?.text = r.text }
        var learner = LineLearner()
        JudgeReplay.teach(&learner, from: a, budget: 20)
        let result = JudgeReplay.result(b, learner: learner)
        XCTAssertEqual(result.flips, 0)
        XCTAssertEqual(result.learned.writingKept, result.base.writingKept)
    }

    func testTheHarnessCoversEveryPairing() {
        let report = JudgeReplay.evaluate([session("a", seed: 1), session("b", seed: 7), session("c", seed: 11)], budget: 15)
        XCTAssertEqual(report.leaveOneOut.count, 3)
        XCTAssertEqual(report.pairs.count, 6)
        XCTAssertEqual(report.within.count, 3)
        for r in report.leaveOneOut { XCTAssertGreaterThanOrEqual(r.learned.writingKept, r.base.writingKept) }
    }
}
