import XCTest
@testable import VoiceFlow

final class DictationGateTests: XCTestCase {
    func testShortHoldIsDiscardedEvenWhenPreRollFilledTheBuffer() {
        let preRollSamples = 6_400
        XCTAssertFalse(
            DictationGate.shouldTranscribe(
                sampleCount: preRollSamples,
                holdDuration: 0.12,
                minimumDuration: 0.3
            )
        )
    }

    func testEmptyCaptureIsDiscarded() {
        XCTAssertFalse(
            DictationGate.shouldTranscribe(
                sampleCount: 0,
                holdDuration: 1.2,
                minimumDuration: 0.3
            )
        )
    }

    func testLongEnoughSpeechIsTranscribed() {
        XCTAssertTrue(
            DictationGate.shouldTranscribe(
                sampleCount: 8_000,
                holdDuration: 0.5,
                minimumDuration: 0.3
            )
        )
    }

    func testBlankTranscriptIsNotPasted() {
        XCTAssertFalse(DictationGate.shouldPaste("   \n"))
        XCTAssertFalse(DictationGate.shouldPaste(""))
    }

    func testTextIsPasted() {
        XCTAssertTrue(DictationGate.shouldPaste("Ship it."))
    }
}
