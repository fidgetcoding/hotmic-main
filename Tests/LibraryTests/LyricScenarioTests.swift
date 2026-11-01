import XCTest
@testable import Library

/// The lyric decoding scenario harness. Every scenario in Fixtures/lyric-scenarios.json runs
/// through `LyricArranger`, the function the window uses.
/// Decided scenarios must match Nate's pick; open ones are reported with the option today's code
/// produces. Prints one table; writes a JSON report to $HM_SCENARIO_REPORT when set.
final class LyricScenarioTests: XCTestCase {
    struct Outcome { let id: String; let status: String; let today: String; let actual: [[String]]; let expected: [[String]]? }

    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/lyric-scenarios.json")

    func testEveryScenario() throws {
        let data = try Data(contentsOf: Self.fixture)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let scenarios = try XCTUnwrap(root["scenarios"] as? [[String: Any]])
        var outcomes: [Outcome] = []
        for s in scenarios {
            let id = s["id"] as? String ?? "?"
            if (s["harness"] as? Bool) == false { outcomes.append(Outcome(id: id, status: "PAGE", today: "-", actual: [], expected: nil)); continue }
            let input = s["input"] as? [String: Any] ?? [:]
            let exact = (s["compare"] as? String) == "exact"
            let slots = LyricArranger.arrange(takes: try Self.takes(input), keepers: [], live: Self.liveLines(input),
                                              protected: Set((input["protect"] as? [String]) ?? []))
            let actual = slots.map { $0.map { Self.render($0) } }
            let options = s["options"] as? [[String: Any]] ?? []
            let sheets = options.map { ($0["key"] as? String ?? "?", Self.sheet($0["sheet"])) }
            let decided = s["decided"] as? String
            let expected = decided.flatMap { d in sheets.first { $0.0 == d }?.1 }
            // "today" = the first option whose sheet matches; a decided scenario passes when ITS sheet matches
            // (two options can show the same lines and differ only in the window, e.g. a section flipper).
            let today = sheets.first { Self.same($0.1, actual, exact: exact) }?.0 ?? "none"
            let status = decided == nil ? "OPEN" : (expected.map { Self.same($0, actual, exact: exact) } ?? false ? "PASS" : "FAIL")
            outcomes.append(Outcome(id: id, status: status, today: today, actual: actual, expected: expected.map { $0.map { $0.map(\.text) } }))
        }
        // The table.
        print("\n LYRIC SCENARIOS  (\(outcomes.count)) ")
        print(" id    status  today  what today's code shows")
        for o in outcomes {
            let shown = o.actual.map { slot in slot.count == 1 ? slot[0] : "[" + slot.joined(separator: " | ") + "]" }.joined(separator: " / ")
            print(" \(o.id.padding(toLength: 5, withPad: " ", startingAt: 0)) \(o.status.padding(toLength: 7, withPad: " ", startingAt: 0)) \(o.today.padding(toLength: 6, withPad: " ", startingAt: 0)) \(shown.prefix(150))")
            if o.status == "FAIL", let e = o.expected {
                print("        expected: " + e.map { $0.count == 1 ? $0[0] : "[" + $0.joined(separator: " | ") + "]" }.joined(separator: " / ").prefix(150))
            }
        }
        let counts = Dictionary(grouping: outcomes, by: \.status).mapValues(\.count)
        print(" PASS \(counts["PASS"] ?? 0) · FAIL \(counts["FAIL"] ?? 0) · OPEN \(counts["OPEN"] ?? 0) · page-only \(counts["PAGE"] ?? 0)\n")
        if let path = ProcessInfo.processInfo.environment["HM_SCENARIO_REPORT"] {
            let report = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.id, ["status": $0.status, "today": $0.today, "actual": $0.actual] as [String: Any]) })
            let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try json.write(to: URL(fileURLWithPath: path))
        }
        for o in outcomes where o.status == "FAIL" { XCTFail("\(o.id): shows option \(o.today), Nate decided otherwise") }
    }

    // MARK: - fixture → input

    struct Expected: Equatable { var text: String; var chords: [String]? }

    static func liveLines(_ input: [String: Any]) -> [LiveLine] {
        if let words = input["words"] as? [[Any]] {
            let timed = words.compactMap { w -> TimedWord? in
                guard let text = w.first as? String, let t = (w.count > 1 ? w[1] : nil) as? Double else { return nil }
                return TimedWord(text: text, start: t, end: t + 0.3)
            }
            let fixes = input["fixes"] as? [Any] ?? []
            return LyricArranger.lines(words: timed).enumerated().map { i, line in
                let fix = i < fixes.count ? fixes[i] as? String : nil
                return LiveLine(text: line.map(\.text).joined(separator: " "), at: line[0].start, end: line[line.count - 1].end,
                                fixed: (fix?.isEmpty ?? true) ? nil : fix)
            }
        }
        return (input["live"] as? [[Any]] ?? []).compactMap { l in
            guard l.count >= 3, let text = l[0] as? String, let at = l[1] as? Double, let end = l[2] as? Double else { return nil }
            let fix = l.count > 3 ? l[3] as? String : nil
            let cut = l.count > 4 ? (l[4] as? Bool ?? false) : false
            return LiveLine(text: text, at: at, end: end, fixed: (fix?.isEmpty ?? true) ? nil : fix, cut: cut ? true : nil)
        }
    }

    static func takes(_ input: [String: Any]) throws -> [TakeRecord] {
        try (input["takes"] as? [[String: Any]] ?? []).map { t in
            let at = t["at"] as? Double ?? 0, dur = t["dur"] as? Double ?? 0
            let text = t["text"] as? String ?? ""
            let words: [[String: Any]] = (t["words"] as? [[Any]])?.compactMap { w in
                guard w.count >= 3, let s = w[0] as? String, let a = w[1] as? Double, let b = w[2] as? Double else { return nil }
                return ["text": s, "start": a, "end": b]
            } ?? []
            let chords: [[String: Any]] = (t["chords"] as? [[Any]])?.compactMap { c in
                guard c.count >= 3, let n = c[0] as? String, let a = c[1] as? Double, let b = c[2] as? Double else { return nil }
                return ["name": n, "start": a, "end": b]
            } ?? []
            var dict: [String: Any] = [
                "id": t["id"] as? String ?? "t", "createdAt": "2026-10-12T23:00:00Z", "daw": "Jam",
                "sessionStartSeconds": at, "durationSeconds": dur, "confidence": 0.9, "route": "speakers", "files": [:] as [String: String],
                "kind": t["kind"] as? String ?? "playing", "lyrics": ["text": text, "words": words], "chords": chords,
            ]
            if text.isEmpty { dict["lyrics"] = nil }
            let data = try JSONSerialization.data(withJSONObject: dict)
            return try LyricSheet.decoder.decode(TakeRecord.self, from: data)
        }
    }

    // MARK: - comparing sheets

    static func render(_ v: LabSession.Version) -> String { v.chords.isEmpty ? v.text : v.text + " {" + v.chords.joined(separator: " ") + "}" }

    static func sheet(_ raw: Any?) -> [[Expected]] {
        (raw as? [[Any]] ?? []).map { slot in
            slot.compactMap { v -> Expected? in
                if let s = v as? String { return Expected(text: s.hasPrefix("★ ") ? String(s.dropFirst(2)) : s, chords: nil) }
                if let d = v as? [String: Any], let s = d["text"] as? String { return Expected(text: s, chords: d["chords"] as? [String]) }
                return nil
            }
        }
    }

    /// Case and spacing don't count; commas and periods do (Nate 2026-10-12: a join or a pause shows as a comma).
    static func norm(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "’", with: "'")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    static func same(_ expected: [[Expected]], _ actual: [[String]], exact: Bool) -> Bool {
        guard expected.count == actual.count else { return false }
        for (e, a) in zip(expected, actual) {
            guard e.count == a.count else { return false }
            for (x, y) in zip(e, a) {
                let (text, chords) = y.hasSuffix("}") ? (String(y[..<y.range(of: " {", options: .backwards)!.lowerBound]), String(y.drop(while: { $0 != "{" }).dropFirst().dropLast()).split(separator: " ").map(String.init)) : (y, [])
                if exact ? (x.text != text) : (norm(x.text) != norm(text)) { return false }
                if let c = x.chords, c != chords { return false }
            }
        }
        return true
    }
}
