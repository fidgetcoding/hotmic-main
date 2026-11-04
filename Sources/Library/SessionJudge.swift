import Capture
import Foundation

/// The judge's work on one session folder: the model pass after Stop, and what your corrections teach it.
public enum SessionJudge {
    /// The session's sung lines in order, before any judging, and what they sounded like.
    public static func rows(folder: URL) -> [SungRow] {
        let notepad = LabSessionExport.unjudged(folder: folder)
        return LineJudge.rows(slots: notepad.slots, takes: notepad.takes)
    }

    /// Compatibility wrapper: on persistence failure returns disk state, not unsaved model answers.
    @discardableResult
    public static func pass(folder: URL, model: LineModel) async -> SessionJudgments {
        do { return try await passChecked(folder: folder, model: model) }
        catch { return SessionJudgments.read(folder) }
    }

    /// Model failures fall back to rules; storage failures throw and leave damaged files untouched.
    @discardableResult
    public static func passChecked(folder: URL, model: LineModel) async throws -> SessionJudgments {
        var stored = try SessionJudgments.readChecked(folder)
        let rows = try rowsChecked(folder: folder)
        var audio = LineAudioCache.read(folder)
        let missing = rows.filter { audio[$0.id] == nil && $0.duration >= 0.5 }
        if !missing.isEmpty {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0.hasPrefix("session__voice_") && $0.hasSuffix(".m4a") }.sorted()
            audio.merge(LineAudio.measure(missing, segments: names.map { folder.appendingPathComponent($0) }, segmentSeconds: 300)) { a, _ in a }
            LineAudioCache.write(audio, to: folder)
        }
        stored = try await ModelPass.run(rows: rows, model: model, into: stored) { try $0.saveModelProgress(to: folder) }
        return try stored.saveModelProgress(to: folder)
    }

    /// How a signal from you counts.
    public enum Signal: Sendable {
        /// One click: this line is a lyric, or isn't. Pinned for this session and taught at full weight.
        case verdict(LineVerdict)
        /// You starred a version of it or edited its words, so it is a lyric. Taught, not pinned.
        case starred, edited
        /// You deleted it from the session, or brought it back with undo. Taught, not pinned.
        case deleted, restored
    }

    /// Compatibility wrappers return persisted state after failure; use learnChecked to handle errors.
    @discardableResult
    public static func learn(_ signal: Signal, lineID id: String, folder: URL, profileURL: URL? = nil) -> LineJudgeProfile {
        learn([(signal, id)], folder: folder, profileURL: profileURL)
    }

    @discardableResult
    public static func learn(_ signals: [(Signal, String)], folder: URL, profileURL: URL? = nil) -> LineJudgeProfile {
        do { return try learnChecked(signals, folder: folder, profileURL: profileURL) }
        catch { return LineJudgeProfile.read(profileURL ?? LineJudgeProfile.url(forSession: folder)) }
    }

    @discardableResult
    public static func learnChecked(_ signal: Signal, lineID id: String, folder: URL, profileURL: URL? = nil) throws -> LineJudgeProfile {
        try learnChecked([(signal, id)], folder: folder, profileURL: profileURL)
    }

    /// Each file is atomic, not a multi-file transaction: if profile saving fails after a pin is saved,
    /// the pin remains and this throws. Callers must not report the learner update as saved.
    @discardableResult
    public static func learnChecked(_ signals: [(Signal, String)], folder: URL, profileURL: URL? = nil) throws -> LineJudgeProfile {
        JudgePersistence.lock.lock(); defer { JudgePersistence.lock.unlock() }
        let url = profileURL ?? LineJudgeProfile.url(forSession: folder)
        var profile = try LineJudgeProfile.readChecked(url)
        var stored = try SessionJudgments.readChecked(folder)
        let rows = try rowsChecked(folder: folder)
        let audio = LineAudioCache.read(folder)
        let input = LineJudge.learningInput(rows, stored: stored, useModel: profile.modelOn, audio: audio)
        let index = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let decisions = LineJudge.decide(rows, stored: stored, learner: profile.learnerOn ? profile.learner : nil, useModel: profile.modelOn, audio: audio)
        var pinned = false
        for (signal, id) in signals {
            guard let i = index[id], let line = input[id] else { continue }
            let (talk, weight): (Bool, Double)
            switch signal {
            case let .verdict(v): (talk, weight) = (v != .writing, 1); stored.corrections[id] = v; pinned = true
            case .starred: (talk, weight) = (false, LineJudgeConfig.weightStar)
            case .edited: (talk, weight) = (false, LineJudgeConfig.weightEdit)
            case .deleted: (talk, weight) = (true, LineJudgeConfig.weightDelete)
            case .restored: (talk, weight) = (false, LineJudgeConfig.weightDelete)
            }
            guard profile.learnerOn else { continue }
            var neighbours: [(x: [Int: Double], talk: Bool, lean: Double)] = []
            for j in [i - 2, i - 1, i + 1, i + 2] where rows.indices.contains(j) {
                if let n = input[rows[j].id], let d = decisions[rows[j].id] { neighbours.append((n.x, d.verdict != .writing, n.lean)) }
            }
            profile.learner.correct(line.x, talk: talk, lean: line.lean, was: decisions[id], weight: weight, neighbours: neighbours)
        }
        if pinned { try stored.writeChecked(to: folder) }
        try profile.writeChecked(to: url)
        HotMicLog.write("line judge: \(signals.count) signal(s) in \(folder.lastPathComponent), \(profile.learner.corrections) correction(s) in all")
        return profile
    }

    /// Preflight live lines before using the display exporter, which otherwise substitutes empty data.
    private static func rowsChecked(folder: URL) throws -> [SungRow] {
        _ = try LiveLines.readChecked(folder)
        return rows(folder: folder)
    }

    public static func linesChecked(in range: HiddenRange, folder: URL) throws -> [String] {
        try rowsChecked(folder: folder).filter { range.covers($0.at, $0.at + $0.duration) }.map(\.id)
    }

    /// Lines sung inside a stretch (what a delete or an undo touches).
    public static func lines(in range: HiddenRange, folder: URL) -> [String] {
        rows(folder: folder).filter { range.covers($0.at, $0.at + $0.duration) }.map(\.id)
    }
}
