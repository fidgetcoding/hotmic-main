import XCTest
@testable import Library

/// Re-run a real session recording through the Freestyle pipeline: HM_REPLAY=<path to session__voice_001.m4a>.
final class ReplayTests: XCTestCase {
    func testReplay() async throws {
        guard let path = ProcessInfo.processInfo.environment["HM_REPLAY"] else { throw XCTSkip("set HM_REPLAY") }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("hm-replay-\(UUID())")
        defer { try? FileManager.default.removeItem(at: out) }
        let takes = try await RecordingImport.run(url: URL(fileURLWithPath: path), folder: out)
        for t in takes { print("REPLAY take at \(String(format: "%.1f", t.sessionStartSeconds)) +\(String(format: "%.1f", t.durationSeconds)) \(t.kind)") }
        print("REPLAY \(takes.count) takes")
    }
}
