import XCTest
@testable import VoiceFlow

final class AudioRingBufferTests: XCTestCase {
    func testSnapshotKeepsTheNewestSamplesInOrder() {
        var ring = AudioRingBuffer(capacity: 4)
        ring.write([1, 2, 3, 4, 5])
        XCTAssertEqual(ring.snapshot(), [2, 3, 4, 5])
    }

    func testSnapshotBeforeWrapIsThePrefix() {
        var ring = AudioRingBuffer(capacity: 8)
        ring.write([1, 2, 3])
        XCTAssertEqual(ring.snapshot(), [1, 2, 3])
    }

    func testEmptySnapshot() {
        let ring = AudioRingBuffer(capacity: 4)
        XCTAssertEqual(ring.snapshot(), [])
    }
}
