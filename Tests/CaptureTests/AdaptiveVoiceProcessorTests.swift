import XCTest
@testable import Capture

final class AdaptiveVoiceProcessorTests: XCTestCase {
    func testHeadphonesReturnsUntouchedMicDelayedByLatency() {
        var config = LinearEchoCanceller.Config()
        config.block = 64; config.partitions = 2
        let processor = AdaptiveVoiceProcessor(sampleRate: 48_000, prior: .headphones,
                                               canceller: LinearEchoCanceller(config: config))
        let input = (0..<640).map { Float($0) / 640 }
        var mic = input
        let ref = [Float](repeating: 0.2, count: 1_280)
        mic.withUnsafeMutableBufferPointer { m in
            ref.withUnsafeBufferPointer { processor.process(mic: m, reference: $0, frames: 640) }
        }
        XCTAssertEqual(processor.latencyFrames, 64)
        XCTAssertEqual(Array(mic[64...]), Array(input[..<576]))
        XCTAssertEqual(processor.route, .headphones)
    }
}
