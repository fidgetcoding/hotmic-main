import Capture
import Foundation

/// The model pass after Stop: a local model reads the session's lines one at a time, each with the lines
/// around it. It only sorts. Fails safe: a model that is missing, refuses, stalls or errors leaves those
/// lines to today's rules, and the outcome goes in the log.
public enum ModelPass {
    /// Judges what isn't judged yet (lines already answered for the same words are kept). Never throws.
    public static func run(rows: [SungRow], model: LineModel, into stored: SessionJudgments,
                           lineTimeout: Double = LineJudgeConfig.modelLineTimeout,
                           passTimeout: Double = LineJudgeConfig.modelPassTimeout,
                           onProgress: (@Sendable (SessionJudgments) -> Void)? = nil) async -> SessionJudgments {
        var out = stored
        let ids = Set(rows.map(\.id))
        out.lines = out.lines.filter { ids.contains($0.key) }      // lines gone from the session
        out.stats.lines = rows.count
        guard model.isAvailable else {
            HotMicLog.write("line judge: \(model.name) unavailable, \(rows.count) line(s) stay with the rules")
            return out
        }
        let started = Date()
        var failuresInARow = 0, asked = 0, refused = 0, timedOut = 0, failed = 0
        let masked = rows.map { ExplicitMask.mask($0.text) }
        for (i, row) in rows.enumerated() {
            if let done = out.lines[row.id], done.text == row.text { continue }      // answered, or refused: not asked twice
            guard Date().timeIntervalSince(started) < passTimeout, !Task.isCancelled else {
                HotMicLog.write("line judge: pass ended early after \(asked) line(s)")
                break
            }
            let before = Array(masked[max(0, i - LineJudgeConfig.contextBefore)..<i])
            let after = Array(masked[(i + 1)..<min(rows.count, i + 1 + LineJudgeConfig.contextAfter)])
            asked += 1
            switch await answer(model, before: before, line: masked[i], after: after, timeout: lineTimeout) {
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
            }
            if failuresInARow >= LineJudgeConfig.maxFailuresInARow {
                HotMicLog.write("line judge: \(model.name) failed \(failuresInARow) lines in a row, the rest stay with the rules")
                break
            }
            if asked % 50 == 0 { onProgress?(out) }
        }
        out.stats.answered = out.lines.values.filter { $0.model != nil }.count
        out.stats.refused = refused; out.stats.timedOut = timedOut; out.stats.failed = failed
        out.stats.seconds += Date().timeIntervalSince(started)
        HotMicLog.write(String(format: "line judge: %@ asked %d of %d line(s), %d answered in all, %d refused, %d timed out, %d failed, %.0f s",
                               model.name, asked, rows.count, out.stats.answered, refused, timedOut, failed, Date().timeIntervalSince(started)))
        return out
    }

    enum Answer: Sendable { case verdict(LineVerdict), refused, timedOut, failed }

    /// One line, raced against the clock. A model call that ignores cancellation can't hold up the pass.
    static func answer(_ model: LineModel, before: [String], line: String, after: [String], timeout: Double) async -> Answer {
        await withCheckedContinuation { (c: CheckedContinuation<Answer, Never>) in
            let once = Once()
            let work = Task {
                do {
                    let v = try await model.judge(before: before, line: line, after: after)
                    if once.claim() { c.resume(returning: v.map(Answer.verdict) ?? .refused) }
                } catch {
                    if once.claim() { c.resume(returning: .failed) }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if once.claim() { work.cancel(); c.resume(returning: .timedOut) }
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
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
