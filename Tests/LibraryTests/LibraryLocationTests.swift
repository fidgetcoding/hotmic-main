import XCTest
@testable import Library

final class LibraryLocationTests: XCTestCase {
    var home: URL!
    override func setUp() {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("hm-home-\(UUID())")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: home) }

    func testPrefersICloudDrive() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"),
                                                withIntermediateDirectories: true)
        XCTAssertTrue(LibraryLocation.defaultLocation(home: home).root.path.hasSuffix("com~apple~CloudDocs/Hot Mic"))
    }

    func testFallsBackToMusic() {
        XCTAssertTrue(LibraryLocation.defaultLocation(home: home).root.path.hasSuffix("Music/Hot Mic"))
    }

    func testSavedChoiceWins() {
        let defaults = UserDefaults(suiteName: "hm-test-\(UUID())")!
        LibraryLocation(root: URL(fileURLWithPath: "/Volumes/NAS/Songs")).save(defaults)
        XCTAssertEqual(LibraryLocation.current(defaults).root.path, "/Volumes/NAS/Songs")
    }
}

final class RetentionTests: XCTestCase {
    func testExpiresOnlyOldSessionRecordingsAndKeepsTakes() throws {
        let fm = FileManager.default
        let sessions = fm.temporaryDirectory.appendingPathComponent("hm-sessions-\(UUID())")
        defer { try? fm.removeItem(at: sessions) }
        let old = sessions.appendingPathComponent("2026-09-01 0900 Ableton Live")
        let fresh = sessions.appendingPathComponent("2026-09-26 2100 Ableton Live")
        for folder in [old, fresh] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in ["session__voice_001.m4a", "session__mix_001.m4a", "take__voice.m4a", "take.json"] {
                fm.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data([1]))
            }
        }
        let now = Date()
        for name in ["session__voice_001.m4a", "session__mix_001.m4a", "take__voice.m4a", "take.json"] {
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-20 * 86_400)],
                                 ofItemAtPath: old.appendingPathComponent(name).path)
        }
        let removed = Retention(days: 14).sweep(sessions, now: now)
        XCTAssertEqual(Set(removed.map(\.lastPathComponent)), ["session__voice_001.m4a", "session__mix_001.m4a"])
        XCTAssertTrue(fm.fileExists(atPath: old.appendingPathComponent("take__voice.m4a").path), "takes are kept forever")
        XCTAssertTrue(fm.fileExists(atPath: fresh.appendingPathComponent("session__voice_001.m4a").path))
    }
}
