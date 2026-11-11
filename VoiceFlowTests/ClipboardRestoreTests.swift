import AppKit
import XCTest
@testable import VoiceFlow

final class ClipboardRestoreTests: XCTestCase {
    func testRestorePutsThePreviousClipboardBack() {
        let pasteboard = NSPasteboard.general
        let original = ClipboardState.save()
        defer { ClipboardState.restore(original) }

        pasteboard.clearContents()
        pasteboard.setString("user-clipboard", forType: .string)
        let saved = ClipboardState.save()

        pasteboard.clearContents()
        pasteboard.setString("transcript that must not stick", forType: .string)
        ClipboardState.restore(saved)

        XCTAssertEqual(pasteboard.string(forType: .string), "user-clipboard")
    }
}
