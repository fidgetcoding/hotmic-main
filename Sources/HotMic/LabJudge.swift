import Capture
import Foundation
import Library

/// The window's side of the line judge: the model pass in the background, corrections from the page, the settings.
extension LabWindowController {
    /// Queues the model pass for a session (after Stop, an import, or opening an older session).
    func judgeSoon(_ folder: URL) {
        guard LineJudgeProfile.read(profileURL).modelOn, FoundationLineModel().isAvailable else { return }
        judgeRunner.onFinished = { [weak self] done in
            guard let self, self.current?.standardizedFileURL.path == done.standardizedFileURL.path else { return }
            self.pushAll()
        }
        judgeRunner.enqueue(folder)
    }

    private var profileURL: URL { library().root.appendingPathComponent(LineJudgeProfile.fileName) }

    /// What the settings show.
    func pushJudge() {
        let p = LineJudgeProfile.read(profileURL)
        js("HM.host.judgeState({modelOn: \(p.modelOn), learnerOn: \(p.learnerOn), corrections: \(p.learner.corrections), modelAvailable: \(FoundationLineModel().isAvailable)})")
    }

    /// The page's judge commands; true when handled.
    func handleJudge(_ cmd: String, id: String?, kind: String?, verdict: String?, modelOn: Bool?, learnerOn: Bool?, reset: Bool?) -> Bool {
        switch cmd {
        case "judgeCorrect":
            guard let id, let verdict = verdict.flatMap(LineVerdict.init(rawValue:)), let folder = openFolder else { return true }
            let url = profileURL
            learning { try SessionJudge.learnChecked(.verdict(verdict), lineID: id, folder: folder, profileURL: url) }
        case "judgeSignal":
            guard let id, let folder = openFolder else { return true }
            let signal: SessionJudge.Signal = kind == "edited" ? .edited : .starred, url = profileURL
            learning(refresh: false) { try SessionJudge.learnChecked(signal, lineID: id, folder: folder, profileURL: url) }
        case "judgeSettings":
            let url = profileURL
            learning {
                let p = try LineJudgeProfile.updateChecked(at: url) { p in
                    if let modelOn { p.modelOn = modelOn }
                    if let learnerOn { p.learnerOn = learnerOn }
                    if reset == true { p.learner = LineLearner() }
                }
                HotMicLog.write("line judge settings: model \(p.modelOn), learner \(p.learnerOn), corrections \(p.learner.corrections)")
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.judgeRunner.setEnabled(p.modelOn)
                        if p.modelOn, let current = self.current { self.judgeSoon(current) }
                    }
                }
            }
        default:
            return false
        }
        return true
    }

    /// Deleting a stretch says its lines weren't worth keeping; undo takes that back.
    func hide(_ range: HiddenRange, in folder: URL) {
        let url = profileURL
        learning {
            try Self.teach(.deleted, range, folder, url)       // before it's hidden: the lines are still there to read
            HiddenRanges.hide(range, in: folder)
        }
    }
    func unhideLast(in folder: URL) {
        let url = profileURL
        learning {
            let last = HiddenRanges.read(folder).last
            HiddenRanges.unhideLast(in: folder)
            if let last { try Self.teach(.restored, last, folder, url) }
        }
    }
    private nonisolated static func teach(_ signal: SessionJudge.Signal, _ range: HiddenRange, _ folder: URL, _ url: URL) throws {
        let ids = try SessionJudge.linesChecked(in: range, folder: folder).prefix(40)
        if !ids.isEmpty { try SessionJudge.learnChecked(ids.map { (signal, $0) }, folder: folder, profileURL: url) }
    }

    /// Off the main thread, one at a time (each reads and rewrites the session's files), then the window catches up.
    private func learning(refresh: Bool = true, _ work: @escaping @Sendable () throws -> Void) {
        judgeQueue.async {
            do { try work() }
            catch {
                // Checked persistence already logged the file/error. Refresh from disk rather than
                // presenting the requested correction/settings as saved.
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated {
                    self?.liveNotice("Couldn't save that change. Check the library folder.")
                    self?.pushAll()
                } }
                return
            }
            guard refresh else { return }
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.pushAll() } }
        }
    }

    private var openFolder: URL? { current ?? model?.currentRecordingFolder }
}

private let judgeQueue = DispatchQueue(label: "io.bluegum.hotmic.judge", qos: .userInitiated)

/// One model pass at a time, in the background, never during a recording.
@MainActor
final class LineJudgeRunner {
    private var waiting: [URL] = []
    private var running: Task<Void, Never>?
    private var paused = false
    private var enabled = true
    var onFinished: ((URL) -> Void)?

    func enqueue(_ folder: URL) {
        if !waiting.contains(folder) { waiting.append(folder) }
        next()
    }

    /// A recording started: stop thinking. What was answered is saved; the pass carries on after Stop.
    func pause() {
        paused = true
        running?.cancel()
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled { running?.cancel() }
        next()
    }

    func resume() {
        paused = false
        next()
    }

    private func next() {
        guard enabled, !paused, running == nil, !waiting.isEmpty else { return }
        let folder = waiting.removeFirst()
        let done: @MainActor @Sendable (Bool, Bool) -> Void = { [weak self] stopped, saved in
            guard let self else { return }
            self.running = nil
            if stopped {
                self.waiting.removeAll { $0 == folder }
                self.waiting.insert(folder, at: 0)
            } else if saved { self.onFinished?(folder) }
            self.next()
        }
        running = Task.detached(priority: .utility) {
            do {
                try await SessionJudge.passChecked(folder: folder, model: FoundationLineModel())
                await done(Task.isCancelled, true)
            } catch {
                await done(false, false) // logged storage failure; do not announce a completed save or retry forever
            }
        }
    }
}
