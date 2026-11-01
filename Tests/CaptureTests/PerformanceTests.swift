import XCTest
@testable import Capture

/// Real-time cost at production settings. Run: HM_PERF=1 swift test -c release --filter PerformanceTests
final class PerformanceTests: XCTestCase {
    func testEchoCancellerRealtimeFactor() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HM_PERF"] == "1", "set HM_PERF=1 (release build)")
        let rate = 48_000, seconds = 10, chunk = 2_400
        var mic = (0..<rate * seconds).map { _ in Float.random(in: -0.1...0.1) }
        let ref = (0..<rate * seconds * 2).map { _ in Float.random(in: -0.3...0.3) }
        let aec = LinearEchoCanceller()
        let start = Date()
        mic.withUnsafeMutableBufferPointer { m in
            ref.withUnsafeBufferPointer { r in
                for s in stride(from: 0, to: m.count - chunk + 1, by: chunk) {
                    aec.process(mic: UnsafeMutableBufferPointer(rebasing: m[s..<s + chunk]),
                                reference: UnsafeBufferPointer(rebasing: r[(2 * s)..<(2 * (s + chunk))]), frames: chunk)
                }
            }
        }
        let cpu = Date().timeIntervalSince(start) / Double(seconds) * 100
        print("HM_PERF echo canceller: \(String(format: "%.1f", cpu))% of one core")
        XCTAssertLessThan(cpu, 5)
    }
}
