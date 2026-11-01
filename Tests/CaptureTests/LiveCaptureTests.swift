import XCTest
@testable import Capture

/// Real hardware: capture must start delivering with nothing playing on the Mac (tap auto-start
/// used to wait for some app to play sound). Run the app version with `--selftest-capture`. (HM_LIVE=1)
final class LiveCaptureTests: XCTestCase {
    func testCaptureDeliversWithSilenceAndWithSound() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HM_LIVE"] == "1", "set HM_LIVE=1 (uses the real mic)")
        for withSound in [false, true] {
            let source = CoreAudioCaptureSource(target: .systemAudio)
            let mic = RingBuffer(capacity: 1 << 20), session = RingBuffer(capacity: 1 << 21)
            var player: Process?
            if withSound {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
                p.arguments = ["/System/Library/Sounds/Submarine.aiff"]; try p.run(); player = p
            }
            try source.start(mic: mic, session: session)
            let deadline = Date().addingTimeInterval(4)
            var firstAt: Double?
            let t0 = Date()
            while Date() < deadline {
                if source.hostTimeAtFirstFrame != 0, firstAt == nil { firstAt = Date().timeIntervalSince(t0) }
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            source.stop(); player?.terminate()
            print("LIVE withSound=\(withSound) firstFrameAfter=\(firstAt.map { String(format: "%.2f s", $0) } ?? "NEVER")")
        }
    }
}
