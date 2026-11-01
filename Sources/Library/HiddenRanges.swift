import Foundation

/// Stretches of a session you deleted (a take, or a range inside one): hidden from the session and its
/// notepad, never erased — the recording and take files stay, and undo brings the stretch back.
/// Saved next to the session as `hidden-ranges.json` (session seconds).
public struct HiddenRange: Codable, Equatable, Sendable {
    public var a: Double, b: Double
    public init(a: Double, b: Double) { self.a = a; self.b = b }
    public func covers(_ x: Double, _ y: Double) -> Bool { let mid = (x + y) / 2; return mid >= a && mid <= b }
}

public enum HiddenRanges {
    public static let fileName = "hidden-ranges.json"
    public static func read(_ folder: URL) -> [HiddenRange] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return [] }
        return (try? JSONDecoder().decode([HiddenRange].self, from: data)) ?? []
    }
    public static func write(_ all: [HiddenRange], to folder: URL) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(all) { try? data.write(to: folder.appendingPathComponent(fileName), options: .atomic) }
    }
    public static func hide(_ r: HiddenRange, in folder: URL) { write(read(folder) + [r], to: folder) }
    /// Undo: the last stretch you hid comes back.
    public static func unhideLast(in folder: URL) { var all = read(folder); if !all.isEmpty { all.removeLast(); write(all, to: folder) } }

    /// The notepad without the hidden stretches: versions sung inside one are dropped, empty lines go.
    public static func filter(_ slots: [[LabSession.Version]], _ hidden: [HiddenRange]) -> [[LabSession.Version]] {
        guard !hidden.isEmpty else { return slots }
        return slots.map { $0.filter { v in !hidden.contains { $0.covers(v.at, v.at + (v.end - v.start)) } } }.filter { !$0.isEmpty }
    }
}
