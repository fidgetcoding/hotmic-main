import XCTest
@testable import Capture

final class RingBufferTests: XCTestCase {
    func testRoundTripAcrossWrap() {
        let ring = RingBuffer(capacity: 8)
        var out = [Float](repeating: 0, count: 8)
        XCTAssertTrue(ring.write([1, 2, 3, 4, 5, 6], count: 6))
        XCTAssertEqual(ring.read(into: &out, count: 4), 4)
        XCTAssertTrue(ring.write([7, 8, 9, 10, 11, 12], count: 6))  // wraps
        XCTAssertEqual(ring.available, 8)
        XCTAssertEqual(ring.read(into: &out, count: 8), 8)
        XCTAssertEqual(out, [5, 6, 7, 8, 9, 10, 11, 12])
    }

    func testFullWriteIsAllOrNothingAndCounted() {
        let ring = RingBuffer(capacity: 4)
        XCTAssertTrue(ring.write([1, 2, 3], count: 3))
        XCTAssertFalse(ring.write([4, 5], count: 2))
        XCTAssertEqual(ring.dropped, 2)
        XCTAssertEqual(ring.available, 3)
    }

    func testReadReturnsOnlyWhatIsAvailable() {
        let ring = RingBuffer(capacity: 4)
        var out = [Float](repeating: 0, count: 4)
        ring.write([1], count: 1)
        XCTAssertEqual(ring.read(into: &out, count: 4), 1)
        XCTAssertEqual(ring.read(into: &out, count: 4), 0)
    }

    func testConcurrentProducerConsumerPreservesOrder() {
        let ring = RingBuffer(capacity: 1024)
        let total = 200_000
        let producer = Thread {
            var next: Float = 0
            var chunk = [Float](repeating: 0, count: 64)
            while next < Float(total) {
                for i in 0..<64 { chunk[i] = next + Float(i) }
                if ring.write(chunk, count: 64) { next += 64 }
            }
        }
        producer.start()
        var expected: Float = 0
        var buf = [Float](repeating: 0, count: 100)
        while expected < Float(total) {
            let n = ring.read(into: &buf, count: 100)
            for i in 0..<n { XCTAssertEqual(buf[i], expected); expected += 1 }
        }
    }
}
