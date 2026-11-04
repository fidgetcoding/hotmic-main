import Capture
import Foundation

/// The model pass after Stop: a local model reads the session's lines one at a time, each with the lines
/// around it. It only sorts. Fails safe: a model that is missing, refuses, stalls or errors leaves those
/// lines to today's rules, and the outcome goes in the log.
public enum ModelPass {
    /// Judges what isn't judged yet (lines already answered for the same words are kept). Only a throwing persistence callback can throw.
    public static func run(rows: [SungRow], model: LineModel, into stored: SessionJudgments,
                           lineTimeout: Double = LineJudgeConfig.modelLineTimeout,
                           passTimeout: Double = LineJudgeConfig.modelPassTimeout,
                           onProgress: (@Sendable (SessionJudgments) throws -> Void)? = nil) async rethrows -> SessionJudgments {
        var out = stored
        let ids = Set(rows.map(\.id))
        out.lines = out.lines.filter { ids.contains($0.key) }      // lines gone from the session
        out.stats.lines = rows.count
        guard model.isAvailable else {
            HotMicLog.write("line judge: \(model.name) unavailable, \(rows.count) line(s) stay with the rules")
            return out
        }
        let started = ProcessInfo.processInfo.systemUptime
        var failuresInARow = 0, asked = 0, refused = 0, timedOut = 0, failed = 0
        let masked = rows.map { ExplicitMask.mask($0.text) }
        lines: for (i, row) in rows.enumerated() {
            if let done = out.lines[row.id], done.text == row.text { continue }      // answered, or refused: not asked twice
            guard (ProcessInfo.processInfo.systemUptime - started) < passTimeout, !Task.isCancelled else {
                HotMicLog.write("line judge: pass ended early after \(asked) line(s)")
                break
            }
            let before = Array(masked[max(0, i - LineJudgeConfig.contextBefore)..<i])
            let after = Array(masked[(i + 1)..<min(rows.count, i + 1 + LineJudgeConfig.contextAfter)])
            asked += 1
            switch await answer(model, before: before, line: masked[i], after: after, timeout: min(lineTimeout, passTimeout - (ProcessInfo.processInfo.systemUptime - started))) {
            case let .verdict(v):
                failuresInARow = 0
                out.lines[row.id] = .init(text: row.text, model: v)
                out.engine = model.name
            case .refused:
                failuresInARow = 0; refused += 1
                out.lines[row.id] = .init(text: row.text, model: nil)
            case .timedOut:
                failuresInARow += 1; timedOut += 1
            case .failed:
                failuresInARow += 1; failed += 1
            case .cancelled:
                break lines
            }
            if failuresInARow >= LineJudgeConfig.maxFailuresInARow {
                HotMicLog.write("line judge: \(model.name) failed \(failuresInARow) lines in a row, the rest stay with the rules")
                break
            }
            if asked % 50 == 0 { try onProgress?(out) }
        }
        out.stats.answered = out.lines.values.filter { $0.model != nil }.count
        out.stats.refused = refused; out.stats.timedOut = timedOut; out.stats.failed = failed
        out.stats.seconds += (ProcessInfo.processInfo.systemUptime - started)
        HotMicLog.write(String(format: "line judge: %@ asked %d of %d line(s), %d answered in all, %d refused, %d timed out, %d failed, %.0f s",
                               model.name, asked, rows.count, out.stats.answered, refused, timedOut, failed, (ProcessInfo.processInfo.systemUptime - started)))
        return out
    }

    enum Answer: Sendable { case verdict(LineVerdict), refused, timedOut, failed, cancelled }

    /// Unstructured tasks let the timeout return even if a model ignores cancellation. The race owns
    /// both tasks, cancels the loser, and explicitly forwards cancellation from the caller.
    static func answer(_ model: LineModel, before: [String], line: String, after: [String], timeout: Double) async -> Answer {
        guard !Task.isCancelled else { return .cancelled }
        guard timeout.isFinite, timeout > 0 else { return .timedOut }
        let race = AnswerRace()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard race.begin(continuation) else { return }
                let work = Task {
                    do {
                        try Task.checkCancellation()
                        let verdict = try await model.judge(before: before, line: line, after: after)
                        race.finish(verdict.map(Answer.verdict) ?? .refused)
                    } catch {
                        race.finish(Task.isCancelled ? .cancelled : .failed)
                    }
                }
                let timer = Task {
                    do { try await Task.sleep(for: .seconds(timeout)) }
                    catch { return }
                    race.finish(.timedOut)
                }
                race.install(work: work, timer: timer)
            }
        } onCancel: {
            race.finish(.cancelled)
        }
    }

    private final class AnswerRace: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Answer?
        private var continuation: CheckedContinuation<Answer, Never>?
        private var work: Task<Void, Never>?
        private var timer: Task<Void, Never>?

        func begin(_ continuation: CheckedContinuation<Answer, Never>) -> Bool {
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
                return false
            }
            self.continuation = continuation
            lock.unlock()
            return true
        }

        func install(work: Task<Void, Never>, timer: Task<Void, Never>) {
            lock.lock()
            let finished = result != nil
            if !finished { self.work = work; self.timer = timer }
            lock.unlock()
            if finished { work.cancel(); timer.cancel() }
        }

        func finish(_ answer: Answer) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            result = answer
            let (continuation, work, timer) = (self.continuation, self.work, self.timer)
            self.continuation = nil; self.work = nil; self.timer = nil
            lock.unlock()
            work?.cancel(); timer?.cancel()
            continuation?.resume(returning: answer)
        }
    }

}

/// Words swapped for "*" in what the model reads, and nowhere else: Apple's on-device model refuses most
/// rap verses as written (measured on the livestream test corpus: 149 of 185 lines under its default guardrails,
/// and still whole batches under the permissive ones). With these masked it answered every line.
/// Nothing masked is stored or shown. The pattern is rot13 so the source doesn't spell it out.
public enum ExplicitMask {
    static let pattern: NSRegularExpression? = {
        let hidden = #"\o(a[v1]tt?[n-m]*|s+h+p*x+[n-m]*|zbgureS[n-m]*|fu[v1]g[n-m]*|o[v1]gpu[n-m]*|ubrf?|nff(rf|ubyr)?|chff[n-m]*|q[v1]px[n-m]*|pbpxf?|phz|frk[n-m]*|gvgf?|gvgg[n-m]*|obbgl|xvyy[n-m]*|fubbg[n-m]*|thaf?|tybpx[n-m]*|snttbg[n-m]*|ergneq[n-m]*)\o"#
        return try? NSRegularExpression(pattern: rot13(hidden), options: [.caseInsensitive])
    }()

    static func rot13(_ s: String) -> String {
        String(s.unicodeScalars.map { u -> Character in
            switch u {
            case "a"..."z": return Character(UnicodeScalar((u.value - 97 + 13) % 26 + 97)!)
            case "A"..."Z": return Character(UnicodeScalar((u.value - 65 + 13) % 26 + 65)!)
            default: return Character(u)
            }
        })
    }

    public static func mask(_ text: String) -> String {
        guard let pattern else { return text }
        return pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "*")
    }
}
