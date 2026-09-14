import Cocoa
import ApplicationServices
import CoreGraphics

// MARK: - PasteResult

enum PasteResult: Equatable {
    case pasted
    case copiedToClipboard
}

// MARK: - TextPaster

/// Pastes transcribed text into the focused text field by simulating Cmd+V.
/// Saves and restores the clipboard around the paste operation to avoid clobbering user data.
/// Requires Accessibility permission for CGEvent posting.
final class TextPaster {

    struct PasteSession {
        let targetApplication: PasteTargetApplication?
        let originalClipboard: String?
        let timestamp: Date
    }

    var onPaste: ((PasteSession) -> Void)?
    var onPasteStart: (() -> Void)?
    var onPasteEnd: (() -> Void)?

    // MARK: - Timing Constants

    /// Delay after writing text to clipboard before simulating Cmd+V.
    static let preKeystrokeDelay: TimeInterval = 0.05

    /// Delay after simulating Cmd+V before restoring the original clipboard.
    static let postKeystrokeDelay: TimeInterval = 0.1

    // MARK: - Virtual Key Codes

    private static let vKeyCode: CGKeyCode = 0x09
    private static let commandKey: CGKeyCode = 0x37

    // MARK: - Paste Target

    struct PasteTargetApplication: Codable, Equatable, Identifiable {
        let bundleIdentifier: String
        let displayName: String

        var id: String { bundleIdentifier }
    }

    // MARK: - Public API

    /// Paste the given text into the currently focused text field.
    /// Returns the result of the paste operation.
    func paste(_ text: String, delay: TimeInterval? = nil) async -> PasteResult {
        guard let targetApp = frontmostApplication() else {
            return .copiedToClipboard
        }

        // Save current clipboard
        let originalClipboard = ClipboardState.save()

        // Write text to clipboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        onPasteStart?()

        // Wait a bit for clipboard to settle
        try? await Task.sleep(nanoseconds: UInt64((delay ?? Self.preKeystrokeDelay) * 1_000_000_000))

        // Simulate Cmd+V
        simulatePaste()

        // Restore clipboard after delay
        let restoredText = text
        try? await Task.sleep(nanoseconds: UInt64(Self.postKeystrokeDelay * 1_000_000_000))
        ClipboardState.restore(originalClipboard)

        let session = PasteSession(
            targetApplication: targetApp,
            originalClipboard: originalClipboard,
            timestamp: Date()
        )
        onPaste?(session)
        onPasteEnd?()

        return .pasted
    }

    // MARK: - Private

    private func frontmostApplication() -> PasteTargetApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        return PasteTargetApplication(
            bundleIdentifier: app.bundleIdentifier ?? "",
            displayName: app.localizedName ?? "Unknown"
        )
    }

    private func simulatePaste() {
        // Press Command
        let cmdDown = CGEvent(keyboardEventSource: nil, virtualKey: Self.commandKey)
        cmdDown?.setType(.keyDown)
        cmdDown?.flags = .maskCommand
        cmdDown?.post(tap: .cghidEventTap)

        // Press V
        let vDown = CGEvent(keyboardEventSource: nil, virtualKey: Self.vKeyCode)
        vDown?.setType(.keyDown)
        vDown?.post(tap: .cghidEventTap)

        // Release V
        let vUp = CGEvent(keyboardEventSource: nil, virtualKey: Self.vKeyCode)
        vUp?.setType(.keyUp)
        vUp?.post(tap: .cghidEventTap)

        // Release Command
        let cmdUp = CGEvent(keyboardEventSource: nil, virtualKey: Self.commandKey)
        cmdUp?.setType(.keyUp)
        cmdUp?.flags = []
        cmdUp?.post(tap: .cghidEventTap)
    }
}

// MARK: - ClipboardState

private struct ClipboardState {
    let data: [[(NSPasteboard.PasteboardType, Data)]]

    static func save() -> ClipboardState {
        let pb = NSPasteboard.general
        let types = pb.types ?? []
        var items: [[(NSPasteboard.PasteboardType, Data)]] = []

        for type in types {
            if let data = pb.data(forType: type) {
                items.append([(type, data)])
            }
        }

        return ClipboardState(data: items)
    }

    static func restore(_ state: ClipboardState?) {
        guard let state else { return }
        let pb = NSPasteboard.general
        pb.clearContents()

        for item in state.data {
            for (type, data) in item {
                pb.setData(data, forType: type)
            }
        }
    }
}
