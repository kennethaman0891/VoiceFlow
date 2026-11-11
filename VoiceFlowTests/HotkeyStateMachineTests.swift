import XCTest
@testable import VoiceFlow

final class HotkeyStateMachineTests: XCTestCase {
    func testHoldStartsAndStops() {
        var machine = HotkeyStateMachine()
        let start = Date()
        XCTAssertEqual(machine.chordBecamePressed(at: start), .startHold)
        XCTAssertEqual(machine.chordBecamePressed(at: start.addingTimeInterval(0.05)), .none)
        XCTAssertEqual(machine.chordBecameReleased(at: start.addingTimeInterval(0.4)), .stopHold)
    }

    func testDoubleTapTogglesHandsFree() {
        var machine = HotkeyStateMachine()
        let start = Date()
        XCTAssertEqual(machine.chordBecamePressed(at: start), .startHold)
        XCTAssertEqual(machine.chordBecameReleased(at: start.addingTimeInterval(0.05)), .stopHold)
        XCTAssertEqual(machine.chordBecamePressed(at: start.addingTimeInterval(0.2)), .toggleHandsFree)
    }

    func testReleaseDuringHandsFreeDoesNotStop() {
        var machine = HotkeyStateMachine()
        let start = Date()
        XCTAssertEqual(machine.chordBecamePressed(at: start), .startHold)
        machine.handsFreeActive = true
        XCTAssertEqual(machine.chordBecameReleased(at: start.addingTimeInterval(0.2)), .none)
    }

    func testEscapeCancelsAndIgnoresTheFollowingRelease() {
        var machine = HotkeyStateMachine()
        let start = Date()
        XCTAssertEqual(machine.chordBecamePressed(at: start), .startHold)
        XCTAssertEqual(machine.escapePressed(), .cancel)
        XCTAssertEqual(machine.chordBecameReleased(at: start.addingTimeInterval(0.2)), .none)
    }

    func testSlowSecondPressStartsAnotherHold() {
        var machine = HotkeyStateMachine()
        let start = Date()
        XCTAssertEqual(machine.chordBecamePressed(at: start), .startHold)
        XCTAssertEqual(machine.chordBecameReleased(at: start.addingTimeInterval(0.1)), .stopHold)
        XCTAssertEqual(machine.chordBecamePressed(at: start.addingTimeInterval(0.6)), .startHold)
    }
}
