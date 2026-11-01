import Enrichment
import XCTest
@testable import Library

/// Synthetic lines only: invented lyrics and invented talk, nothing from any recording.
private struct StubModel: LineModel {
    var name = "stub"
    var isAvailable = true
    var answer: @Sendable (String) async throws -> LineVerdict?
    func judge(before: [String], line: String, after: [String]) async throws -> LineVerdict? { try await answer(line) }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock(); private var seen: [String] = []
    func add(_ s: String) { lock.withLock { seen.append(s) } }
    var lines: [String] { lock.withLock { seen } }
}

final class ExplicitMaskTests: XCTestCase {
    func testMasksOnlyTheListedWords() {
        XCTAssertEqual(ExplicitMask.mask("pull up with the shit and the guns"), "pull up with the * and the *")
        XCTAssertEqual(ExplicitMask.mask("moonlight on my new song"), "moonlight on my new song")
        XCTAssertEqual(ExplicitMask.mask("Glass houses"), "Glass houses", "whole words, not parts of words")
    }

    func testTheSourceDoesNotSpellTheListOut() {
        XCTAssertEqual(ExplicitMask.rot13("uryyb"), "hello")
    }
}

final class FoundationLineModelTests: XCTestCase {
    func testReadsItsOneWordAnswers() {
        XCTAssertEqual(FoundationLineModel.parse("LYRIC"), .writing)
        XCTAssertEqual(FoundationLineModel.parse("Talk."), .talk)
        XCTAssertNil(FoundationLineModel.parse("I'm sorry, I can't help with that."), "a refusal in words is no answer")
    }

    func testPromptMarksTheLine() {
        let p = FoundationLineModel.prompt(before: ["a"], line: "b", after: ["c"])
        XCTAssertTrue(p.contains("  a\n>> b\n  c\n"))
    }
}

final class LineSmootherTests: XCTestCase {
    let t = LineSmoother.modelEvidence, w = -LineSmoother.modelEvidence

    func testOneOddAnswerInsideAStretchIsOutvoted() {
        let states = LineSmoother.run(evidence: [t, t, t, w, t, t, t])
        XCTAssertTrue(states.allSatisfy(\.talk))
        XCTAssertLessThan(states[3].probability, states[1].probability)
    }

    func testLongStretchesStay() {
        let states = LineSmoother.run(evidence: [w, w, w, w, w, t, t, t, t, t])
        XCTAssertEqual(states.map(\.talk), [false, false, false, false, false, true, true, true, true, true])
    }

    func testEdges() {
        XCTAssertEqual(LineSmoother.run(evidence: []), [])
        XCTAssertTrue(LineSmoother.run(evidence: [t])[0].talk)
        XCTAssertEqual(LineSmoother.run(evidence: [0])[0].probability, 0.5, accuracy: 0.001)
    }
}

final class ModelPassTests: XCTestCase {
    private func rows(_ texts: [String]) -> [SungRow] {
        texts.enumerated().map { SungRow(id: "t#\($0)", takeID: "t", text: $1, at: Double($0), duration: 2) }
    }

    func testUnavailableModelLeavesTheRulesInCharge() async {
        let model = StubModel(isAvailable: false) { _ in XCTFail("never asked"); return .talk }
        let r = rows(["what's up everybody", "moonlight on my new song"])
        let out = await ModelPass.run(rows: r, model: model, into: SessionJudgments())
        XCTAssertNil(out.engine)
        XCTAssertTrue(out.lines.isEmpty)
        let d = LineJudge.decide(r, stored: out)
        XCTAssertTrue(d.values.allSatisfy { $0.source == .rules && $0.verdict == .writing })
    }

    func testARefusedLineStaysWithTheRules() async {
        let model = StubModel { $0.contains("refuse") ? nil : .talk }
        let r = rows(["one two three", "please refuse me", "four five six"])
        let out = await ModelPass.run(rows: r, model: model, into: SessionJudgments())
        XCTAssertEqual(out.stats.refused, 1)
        XCTAssertEqual(out.engine, "stub")
        let d = LineJudge.decide(r, stored: out)
        XCTAssertEqual(d["t#0"]?.source, .model)
        XCTAssertEqual(d["t#1"]?.source, .rules)
        XCTAssertEqual(d["t#1"]?.verdict, .writing)
    }

    func testATimeoutFallsBackAndTheModelIsNotWaitedFor() async {
        let model = StubModel { line in
            if line.contains("stall") { try? await Task.sleep(nanoseconds: 30_000_000_000) }
            return .talk
        }
        let started = Date()
        let out = await ModelPass.run(rows: rows(["stall here", "fine here"]), model: model, into: SessionJudgments(), lineTimeout: 0.05)
        XCTAssertEqual(out.stats.timedOut, 1)
        XCTAssertNil(out.lines["t#0"]?.model)
        XCTAssertEqual(out.lines["t#1"]?.model, .talk)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testAModelThatKeepsFailingIsGivenUpOn() async {
        struct Boom: Error {}
        let calls = Recorder()
        let model = StubModel { calls.add($0); throw Boom() }
        let out = await ModelPass.run(rows: rows((0..<20).map { "line \($0)" }), model: model, into: SessionJudgments())
        XCTAssertEqual(calls.lines.count, LineJudgeConfig.maxFailuresInARow)
        XCTAssertNil(out.engine)
    }

    func testOnlyNewOrChangedLinesAreAskedAgain() async {
        let calls = Recorder()
        let model = StubModel { calls.add($0); return .writing }
        let r = rows(["same words", "other words"])
        var stored = await ModelPass.run(rows: r, model: model, into: SessionJudgments())
        XCTAssertEqual(calls.lines.count, 2)
        stored = await ModelPass.run(rows: [r[0], SungRow(id: "t#1", takeID: "t", text: "fixed words", at: 1, duration: 2)], model: model, into: stored)
        XCTAssertEqual(calls.lines, ["same words", "other words", "fixed words"])
    }

    func testTheModelReadsMaskedWordsButTheAnswerKeepsTheRealOnes() async {
        let calls = Recorder()
        let model = StubModel { calls.add($0); return .writing }
        let out = await ModelPass.run(rows: rows(["that shit hits"]), model: model, into: SessionJudgments())
        XCTAssertEqual(calls.lines, ["that * hits"])
        XCTAssertEqual(out.lines["t#0"]?.text, "that shit hits")
    }
}

final class LineJudgeApplyTests: XCTestCase {
    private func v(_ id: String, _ text: String, at: Double) -> LabSession.Version {
        LabSession.Version(id: id, takeID: "t", text: text, start: 0, end: 2, at: at, words: [], chords: [], keeper: false)
    }

    func testRowsComeOutInTheOrderSung() {
        // Versions are grouped across the session in the notepad; a judge has to read them as they happened.
        let slots = [[v("t#0", "a", at: 1), v("t#5", "a again", at: 9)], [v("t#2", "b", at: 4)]]
        XCTAssertEqual(LineJudge.rows(slots: slots, takes: []).map(\.id), ["t#0", "t#2", "t#5"])
    }

    func testTheRulesAloneHideNothing() {
        let slots = [[v("t#0", "let me run it back", at: 1)]]
        let rows = LineJudge.rows(slots: slots, takes: [])
        let d = LineJudge.decide(rows, stored: SessionJudgments())
        XCTAssertEqual(d["t#0"], .init(verdict: .talk, source: .rules), "the chatter list still judges it talk")
        XCTAssertEqual(LineJudge.apply(slots, decisions: d, stored: SessionJudgments()).slots.count, 1, "but only the whole song drops it, as before")
    }

    func testTalkLeavesTheNotepadAndWordsNeverChange() {
        let talk = (0..<4).map { "yo thanks for coming \($0)" }, song = (0..<4).map { "moonlight on my new song \($0)" }
        let slots = (talk + song).enumerated().map { [v("t#\($0)", $1, at: Double($0))] }
        var stored = SessionJudgments()
        for (i, text) in (talk + song).enumerated() { stored.lines["t#\(i)"] = .init(text: text, model: i < 4 ? .talk : .writing) }
        let rows = LineJudge.rows(slots: slots, takes: [])
        let out = LineJudge.apply(slots, decisions: LineJudge.decide(rows, stored: stored), stored: stored)
        XCTAssertEqual(out.slots.flatMap { $0 }.map(\.text), song)
        XCTAssertEqual(out.aside.map(\.text), talk)
        XCTAssertEqual(out.aside.first?.source, .model)
    }

    func testAnAnswerForOtherWordsIsIgnored() {
        let row = SungRow(id: "t#0", takeID: "t", text: "the words now", at: 0, duration: 1)
        var stored = SessionJudgments()
        stored.lines = ["t#0": .init(text: "the words then", model: .talk)]
        XCTAssertEqual(LineJudge.decide([row], stored: stored)["t#0"]?.source, .rules)
    }

    func testYourClickAlwaysWins() {
        let row = SungRow(id: "t#0", takeID: "t", text: "words", at: 0, duration: 1)
        var stored = SessionJudgments()
        stored.lines = ["t#0": .init(text: "words", model: .talk)]
        stored.corrections = ["t#0": .writing]
        XCTAssertEqual(LineJudge.decide([row], stored: stored)["t#0"], .init(verdict: .writing, source: .you))
    }

    func testTheModelOffSwitchBringsBackTheRules() {
        let row = SungRow(id: "t#0", takeID: "t", text: "words", at: 0, duration: 1)
        var stored = SessionJudgments()
        stored.lines = ["t#0": .init(text: "words", model: .talk)]
        XCTAssertEqual(LineJudge.decide([row], stored: stored, useModel: false)["t#0"]?.source, .rules)
    }
}

final class SessionFolderJudgeTests: XCTestCase {
    private var root: URL!
    private var folder: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        folder = root.appendingPathComponent("Sessions/one", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var take = TakeRecord(id: "t1", createdAt: Date(), daw: "Jam", sessionStartSeconds: 0, durationSeconds: 8, confidence: 1, route: "mic", files: [:])
        take.kind = "rap"
        let lines = ["yo thanks for coming through,", "moonlight on my brand new song,"]
        var words: [Lyrics.Word] = [], t = 0.0
        for w in lines.joined(separator: " ").split(separator: " ") { words.append(Lyrics.Word(text: String(w), start: t, end: t + 0.3)); t += 0.3 }
        take.lyrics = Lyrics(text: lines.joined(separator: " "), words: words)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(take).write(to: folder.appendingPathComponent("t1.json"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testASessionNobodyJudgedLooksExactlyAsBefore() {
        let plain = LabSessionExport.unjudged(folder: folder).slots
        XCTAssertFalse(plain.isEmpty)
        let session = LabSessionExport.session(folder: folder)
        XCTAssertNil(session.judge)
        XCTAssertEqual(session.slots.flatMap { $0 }.map(\.id), plain.flatMap { $0 }.map(\.id))
    }

    func testAJudgedLineLeavesTheSessionAndComesBackWithOneClick() throws {
        let rows = SessionJudge.rows(folder: folder)
        let talk = try XCTUnwrap(rows.first { $0.text.contains("thanks") })
        var stored = SessionJudgments()
        stored.engine = "stub"
        for r in rows { stored.lines[r.id] = .init(text: r.text, model: .writing) }
        stored.corrections[talk.id] = .talk       // a click moves that line, and no other
        stored.write(to: folder)

        var session = LabSessionExport.session(folder: folder)
        XCTAssertEqual(session.judge?.model, "stub")
        XCTAssertEqual(session.judge?.aside.map(\.id), [talk.id])
        XCTAssertFalse(session.slots.flatMap { $0 }.contains { $0.id == talk.id })
        XCTAssertFalse(WholeSong.plan(session.slots).flatMap(\.lines).contains { $0.contains("thanks") }, "the whole song skips it too")

        SessionJudge.learn(.verdict(.writing), lineID: talk.id, folder: folder)
        session = LabSessionExport.session(folder: folder)
        XCTAssertTrue(session.slots.flatMap { $0 }.contains { $0.id == talk.id })
        XCTAssertEqual(LineJudgeProfile.read(root.appendingPathComponent(LineJudgeProfile.fileName)).learner.corrections, 1)
    }

    func testThePassKeepsYourClicksAndTheRawLogs() async throws {
        let before = try Data(contentsOf: folder.appendingPathComponent("t1.json"))
        let rows = SessionJudge.rows(folder: folder)
        SessionJudge.learn(.verdict(.talk), lineID: rows[0].id, folder: folder)
        let stored = await SessionJudge.pass(folder: folder, model: StubModel { _ in .writing })
        XCTAssertEqual(stored.corrections[rows[0].id], .talk)
        XCTAssertEqual(SessionJudgments.read(folder).stats.lines, rows.count)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("t1.json")), before)
    }

    func testStarsTeachButDoNotPin() throws {
        let rows = SessionJudge.rows(folder: folder)
        let profile = SessionJudge.learn(.starred, lineID: rows[0].id, folder: folder)
        XCTAssertEqual(profile.learner.corrections, 1)
        XCTAssertTrue(SessionJudgments.read(folder).corrections.isEmpty)
    }

    func testLearnerOffLearnsNothing() throws {
        var profile = LineJudgeProfile(); profile.learnerOn = false
        profile.write(to: LineJudgeProfile.url(forSession: folder))
        let rows = SessionJudge.rows(folder: folder)
        let after = SessionJudge.learn(.verdict(.talk), lineID: rows[0].id, folder: folder)
        XCTAssertEqual(after.learner.corrections, 0)
        XCTAssertEqual(SessionJudgments.read(folder).corrections[rows[0].id], .talk, "the click itself still counts")
    }
}
