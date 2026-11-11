import Foundation

/// Pure hold-to-talk decisions. The event tap feeds this; tests drive it with dates.
struct HotkeyStateMachine {
    enum Effect: Equatable {
        case none
        case startHold
        case stopHold
        case toggleHandsFree
        case cancel
    }

    var chordIsHeld = false
    var handsFreeActive = false
    var lastRelease = Date.distantPast
    var doubleTapWindow: TimeInterval = 0.35

    mutating func chordBecamePressed(at now: Date) -> Effect {
        guard !chordIsHeld else { return .none }
        chordIsHeld = true
        if now.timeIntervalSince(lastRelease) < doubleTapWindow {
            lastRelease = .distantPast
            return .toggleHandsFree
        }
        return .startHold
    }

    mutating func chordBecameReleased(at now: Date) -> Effect {
        guard chordIsHeld else { return .none }
        chordIsHeld = false
        lastRelease = now
        if handsFreeActive {
            return .none
        }
        return .stopHold
    }

    mutating func escapePressed() -> Effect {
        chordIsHeld = false
        handsFreeActive = false
        lastRelease = .distantPast
        return .cancel
    }
}
