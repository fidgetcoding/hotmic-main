import XCTest
@testable import Library

final class PersistenceSafetyTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    private let damaged = Data("{broken json: preserve these bytes".utf8)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        folder = root.appendingPathComponent("Sessions/fixture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testCorruptLiveLinesSurviveAppendPasteAndFix() throws {
        let url = folder.appendingPathComponent(LiveLines.fileName)
        for action in 0..<3 {
            try damaged.write(to: url)
            switch action {
            case 0: LiveLines.append(LiveLine(text: "new lyric", at: 1, end: 2), to: folder)
            case 1: LiveLines.type("new typed lyric", at: 1, to: folder)
            default: LiveLines.fix(at: 1, text: "corrected lyric", in: folder)
            }
            XCTAssertEqual(try Data(contentsOf: url), damaged)
        }
    }

    func testCorruptJudgmentsSurviveDirectWrite() throws {
        let url = folder.appendingPathComponent(SessionJudgments.fileName)
        try damaged.write(to: url)
        SessionJudgments().write(to: folder)
        XCTAssertEqual(try Data(contentsOf: url), damaged)
    }

    func testCorruptProfileSurvivesSettingsAndDirectWrite() throws {
        let url = LineJudgeProfile.url(forSession: folder)
        try damaged.write(to: url)
        LineJudgeProfile.update(at: url) { $0.modelOn = false }
        XCTAssertEqual(try Data(contentsOf: url), damaged)
        try damaged.write(to: url)
        LineJudgeProfile().write(to: url)
        XCTAssertEqual(try Data(contentsOf: url), damaged)
    }

    func testFailedLearningDoesNotReturnUnsavedCorrections() throws {
        LiveLines.append(LiveLine(text: "moonlight carries the melody", at: 1, end: 3), to: folder)
        let row = try XCTUnwrap(SessionJudge.rows(folder: folder).first)
        // A regular file where a directory is needed fails deterministically, even as root.
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data("keep me".utf8).write(to: blocker)
        let result = SessionJudge.learn(.starred, lineID: row.id, folder: folder,
                                       profileURL: blocker.appendingPathComponent(LineJudgeProfile.fileName))
        XCTAssertEqual(result.learner.corrections, 0, "never return a learned profile that failed to save")
        XCTAssertEqual(try Data(contentsOf: blocker), Data("keep me".utf8))
    }
    private func seedLine() throws -> SungRow {
        XCTAssertTrue(LiveLines.append(LiveLine(text: "moonlight carries the melody", at: 1, end: 3), to: folder))
        return try XCTUnwrap(SessionJudge.rows(folder: folder).first)
    }

    func testMissingLineCorrectionDoesNotClaimItWasSaved() throws {
        _ = try seedLine()
        let url = folder.appendingPathComponent(LiveLines.fileName)
        let before = try Data(contentsOf: url)
        XCTAssertFalse(LiveLines.fix(at: 99, text: "unmatched correction", in: folder))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testMissingStoresInitializeAndValidDataRoundTrips() throws {
        XCTAssertEqual(try LiveLines.readChecked(folder), [])
        XCTAssertEqual(try SessionJudgments.readChecked(folder), SessionJudgments())
        let url = LineJudgeProfile.url(forSession: folder)
        XCTAssertEqual(try LineJudgeProfile.readChecked(url), LineJudgeProfile())
        let row = try seedLine()
        let profile = try SessionJudge.learnChecked(.verdict(.talk), lineID: row.id, folder: folder)
        XCTAssertEqual(profile.learner.corrections, 1)
        XCTAssertEqual(try LineJudgeProfile.readChecked(url), profile)
        XCTAssertEqual(try SessionJudgments.readChecked(folder).corrections[row.id], .talk)
    }

    func testMalformedAndUnreadableStoresReportFailure() throws {
        let lineURL = folder.appendingPathComponent(LiveLines.fileName)
        let judgmentURL = folder.appendingPathComponent(SessionJudgments.fileName)
        let profileURL = LineJudgeProfile.url(forSession: folder)
        for url in [lineURL, judgmentURL, profileURL] { try damaged.write(to: url) }
        XCTAssertThrowsError(try LiveLines.readChecked(folder))
        XCTAssertThrowsError(try SessionJudgments.readChecked(folder))
        XCTAssertThrowsError(try LineJudgeProfile.readChecked(profileURL))
        XCTAssertFalse(LiveLines.append(LiveLine(text: "new words", at: 1, end: 2), to: folder))
        XCTAssertFalse(SessionJudgments().write(to: folder))
        XCTAssertFalse(LineJudgeProfile().write(to: profileURL))
        // Directories cannot be decoded as files; don't treat a read failure as absence.
        for url in [lineURL, judgmentURL, profileURL] {
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try damaged.write(to: url.appendingPathComponent("sentinel"))
        }
        XCTAssertFalse(LiveLines.type("new words", at: 1, to: folder))
        XCTAssertFalse(SessionJudgments().write(to: folder))
        XCTAssertFalse(LineJudgeProfile().write(to: profileURL))
        for url in [lineURL, judgmentURL, profileURL] {
            XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("sentinel")), damaged)
        }
    }

    func testPermissionDeniedReadsPreserveExistingBytes() throws {
        _ = try seedLine()
        XCTAssertTrue(SessionJudgments().write(to: folder))
        let profile = LineJudgeProfile.url(forSession: folder)
        XCTAssertTrue(LineJudgeProfile().write(to: profile))
        let urls = [folder.appendingPathComponent(LiveLines.fileName), folder.appendingPathComponent(SessionJudgments.fileName), profile]
        let original = try urls.map { try Data(contentsOf: $0) }
        defer { for url in urls { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) } }
        for url in urls { try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path) }
        if (try? Data(contentsOf: urls[0])) != nil { throw XCTSkip("Runner can read mode-000 files; permission-denial fixture is unavailable") }
        XCTAssertFalse(LiveLines.append(LiveLine(text: "new words", at: 4, end: 5), to: folder))
        XCTAssertFalse(SessionJudgments().write(to: folder))
        XCTAssertFalse(LineJudgeProfile().write(to: profile))
        for (url, bytes) in zip(urls, original) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testDanglingSymlinksAreNotReplacedAsMissingFiles() throws {
        let urls = [folder.appendingPathComponent(LiveLines.fileName),
                    folder.appendingPathComponent(SessionJudgments.fileName), LineJudgeProfile.url(forSession: folder)]
        for url in urls { try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "missing-target") }
        XCTAssertFalse(LiveLines.append(LiveLine(text: "new words", at: 1, end: 2), to: folder))
        XCTAssertFalse(SessionJudgments().write(to: folder))
        XCTAssertFalse(LineJudgeProfile().write(to: urls[2]))
        for url in urls {
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url.path), "missing-target")
        }
    }

    func testDeterministicWriteFailuresAreObservable() throws {
        let missing = root.appendingPathComponent("missing-parent/session")
        XCTAssertFalse(LiveLines.append(LiveLine(text: "new words", at: 1, end: 2), to: missing))
        XCTAssertFalse(SessionJudgments().write(to: missing))
        XCTAssertFalse(LineJudgeProfile().write(to: missing.appendingPathComponent(LineJudgeProfile.fileName)))
        XCTAssertThrowsError(try SessionJudgments().writeChecked(to: missing)) { error in
            XCTAssertEqual((error as? PersistenceFailure)?.operation, "write")
        }
        XCTAssertThrowsError(try LineJudgeProfile.updateChecked(at: missing.appendingPathComponent(LineJudgeProfile.fileName)) { $0.modelOn = false }) { error in
            XCTAssertEqual((error as? PersistenceFailure)?.operation, "write")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testEncodingFailurePreservesExistingValidFiles() throws {
        _ = try seedLine()
        let lineURL = folder.appendingPathComponent(LiveLines.fileName)
        let originalLines = try Data(contentsOf: lineURL)
        XCTAssertFalse(LiveLines.append(LiveLine(text: "bad time", at: .nan, end: 5), to: folder))
        XCTAssertEqual(try Data(contentsOf: lineURL), originalLines)

        var judgments = SessionJudgments()
        XCTAssertTrue(judgments.write(to: folder))
        let judgmentURL = folder.appendingPathComponent(SessionJudgments.fileName)
        let originalJudgments = try Data(contentsOf: judgmentURL)
        judgments.stats.seconds = .nan
        XCTAssertFalse(judgments.write(to: folder))
        XCTAssertEqual(try Data(contentsOf: judgmentURL), originalJudgments)

        var profile = LineJudgeProfile()
        let profileURL = LineJudgeProfile.url(forSession: folder)
        XCTAssertTrue(profile.write(to: profileURL))
        let originalProfile = try Data(contentsOf: profileURL)
        profile.learner.correct([64: .nan], talk: true, lean: 0)
        XCTAssertFalse(profile.write(to: profileURL))
        XCTAssertEqual(try Data(contentsOf: profileURL), originalProfile)
    }

    func testCorruptLearningInputsAbortBeforeOtherFilesChange() throws {
        let row = try seedLine()
        let profileURL = LineJudgeProfile.url(forSession: folder)
        let judgmentURL = folder.appendingPathComponent(SessionJudgments.fileName)
        XCTAssertTrue(LineJudgeProfile().write(to: profileURL))
        XCTAssertTrue(SessionJudgments().write(to: folder))
        let profileBefore = try Data(contentsOf: profileURL)
        let judgmentBefore = try Data(contentsOf: judgmentURL)
        try damaged.write(to: judgmentURL)
        XCTAssertThrowsError(try SessionJudge.learnChecked(.verdict(.talk), lineID: row.id, folder: folder))
        XCTAssertEqual(try Data(contentsOf: judgmentURL), damaged)
        XCTAssertEqual(try Data(contentsOf: profileURL), profileBefore)
        try judgmentBefore.write(to: judgmentURL)
        try damaged.write(to: profileURL)
        XCTAssertThrowsError(try SessionJudge.learnChecked(.starred, lineID: row.id, folder: folder))
        XCTAssertEqual(try Data(contentsOf: profileURL), damaged)
        XCTAssertEqual(try Data(contentsOf: judgmentURL), judgmentBefore)
    }

    func testMissingProfileParentThrowsRatherThanReturningSavedLearning() throws {
        let row = try seedLine()
        let url = root.appendingPathComponent("missing-parent/profile.json")
        XCTAssertThrowsError(try SessionJudge.learnChecked(.starred, lineID: row.id, folder: folder, profileURL: url)) { error in
            XCTAssertEqual((error as? PersistenceFailure)?.operation, "write")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let fallback = SessionJudge.learn(.starred, lineID: row.id, folder: folder, profileURL: url)
        XCTAssertEqual(fallback.learner.corrections, 0)
    }

    func testFailedProfileSaveDoesNotUndoAnAlreadySavedPin() throws {
        let row = try seedLine()
        let url = root.appendingPathComponent("missing-parent/profile.json")
        XCTAssertThrowsError(try SessionJudge.learnChecked(.verdict(.talk), lineID: row.id, folder: folder, profileURL: url))
        XCTAssertEqual(try SessionJudgments.readChecked(folder).corrections[row.id], .talk)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCorruptInputStopsModelPassBeforeAnyRequest() async throws {
        _ = try seedLine()
        let url = folder.appendingPathComponent(SessionJudgments.fileName)
        try damaged.write(to: url)
        let model = PersistenceProbeModel()
        do { try await SessionJudge.passChecked(folder: folder, model: model); XCTFail("must throw") }
        catch { XCTAssertTrue(error is PersistenceFailure) }
        XCTAssertEqual(model.calls, 0)
        XCTAssertEqual(try Data(contentsOf: url), damaged)
        try FileManager.default.removeItem(at: url)
        let live = folder.appendingPathComponent(LiveLines.fileName)
        try damaged.write(to: live)
        do { try await SessionJudge.passChecked(folder: folder, model: model); XCTFail("must throw") }
        catch { XCTAssertTrue(error is PersistenceFailure) }
        XCTAssertEqual(model.calls, 0)
        XCTAssertEqual(try Data(contentsOf: live), damaged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCheckpointFailureStopsThePassAndPreservesDamagedData() async throws {
        let lines = (0..<60).map { LiveLine(text: "unique melody line number \($0) carries the moonlight", at: Double($0) * 4, end: Double($0) * 4 + 2) }
        try JSONEncoder().encode(lines).write(to: folder.appendingPathComponent(LiveLines.fileName))
        XCTAssertEqual(SessionJudge.rows(folder: folder).count, 60)
        let url = folder.appendingPathComponent(SessionJudgments.fileName), damaged = self.damaged
        let model = PersistenceProbeModel { count in if count == 50 { try damaged.write(to: url) } }
        do { try await SessionJudge.passChecked(folder: folder, model: model); XCTFail("must throw at checkpoint") }
        catch { XCTAssertTrue(error is PersistenceFailure) }
        XCTAssertEqual(model.calls, 50)
        XCTAssertEqual(try Data(contentsOf: url), damaged)
    }

    func testFinalSaveFailureThrowsAndCompatibilityPassReturnsDiskState() async throws {
        _ = try seedLine()
        let url = folder.appendingPathComponent(SessionJudgments.fileName), damaged = self.damaged
        let model = PersistenceProbeModel { _ in try damaged.write(to: url) }
        do { try await SessionJudge.passChecked(folder: folder, model: model); XCTFail("must throw at final save") }
        catch { XCTAssertTrue(error is PersistenceFailure) }
        XCTAssertEqual(model.calls, 1)
        XCTAssertEqual(try Data(contentsOf: url), damaged)
        let result = await SessionJudge.pass(folder: folder, model: model)
        XCTAssertNil(result.engine)
        XCTAssertTrue(result.lines.isEmpty)
        XCTAssertEqual(model.calls, 1)
    }

}

private final class PersistenceProbeModel: LineModel, @unchecked Sendable {
    let name = "offline-persistence-fixture"
    let isAvailable = true
    private let lock = NSLock()
    private var count = 0
    private let onCall: @Sendable (Int) throws -> Void
    init(onCall: @escaping @Sendable (Int) throws -> Void = { _ in }) { self.onCall = onCall }
    var calls: Int { lock.withLock { count } }
    func judge(before: [String], line: String, after: [String]) async throws -> LineVerdict? {
        let n = lock.withLock { count += 1; return count }
        try onCall(n)
        return .writing
    }
}
