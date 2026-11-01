import Foundation

/// Where the beat was when each Beat-mode recording started (Nate 2026-10-14): the session time Record was
/// pressed, the beat position it started from, and the loop. Playback with the loop on lines your recording
/// back up with the beat from this. Saved next to the session as `beat-runs.json`, appended per recording.
public struct BeatRun: Codable, Equatable, Sendable {
    public var at: Double          // session seconds when this recording started
    public var beat: Double        // beat seconds it started from
    public var loopA: Double, loopB: Double
    public var loopOn: Bool
    public var beatName: String?
    public init(at: Double, beat: Double, loopA: Double, loopB: Double, loopOn: Bool, beatName: String? = nil) {
        self.at = at; self.beat = beat; self.loopA = loopA; self.loopB = loopB; self.loopOn = loopOn; self.beatName = beatName
    }
}

public enum BeatRuns {
    public static let fileName = "beat-runs.json"
    public static func read(_ folder: URL) -> [BeatRun] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return [] }
        return (try? JSONDecoder().decode([BeatRun].self, from: data)) ?? []
    }
    public static func append(_ run: BeatRun, to folder: URL) {
        let all = read(folder) + [run]
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(all) { try? data.write(to: folder.appendingPathComponent(fileName), options: .atomic) }
    }
}
