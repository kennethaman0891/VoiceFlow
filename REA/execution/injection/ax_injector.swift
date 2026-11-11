import Cocoa
import ApplicationServices
import CoreGraphics

// MARK: - InjectionResult

public enum InjectionResult: Equatable, Sendable {
    case directAccessibility
    case clipboardSimulatedPaste
    case clipboardCopiedOnly
    case failed(String)
}

// MARK: - DirectAXInjector

/// High-performance text injector that prioritizes direct macOS Accessibility API
/// value setting over synthetic keyboard shortcuts.
///
/// Direct AX injection avoids clobbering the user's clipboard and prevents triggering
/// clipboard manager histories (such as Raycast, Alfred, Maccy).
public final class DirectAXInjector: @unchecked Sendable {
    public static let shared = DirectAXInjector()

    private let pasteboard = NSPasteboard.general
    private let serialQueue = DispatchQueue(label: "com.voiceflow.axinjector", qos: .userInteractive)

    public init() {}

    /// Injects text into the currently focused element across the macOS window server.
    public func inject(text: String, allowClipboardFallback: Bool = true) async -> InjectionResult {
        await withCheckedContinuation { continuation in
            serialQueue.async {
                // 1. Attempt direct Accessibility API injection
                if self.attemptDirectAXInjection(text: text) {
                    continuation.resume(returning: .directAccessibility)
                    return
                }

                // 2. If AX fails and fallback is enabled, use atomic clipboard swap
                if allowClipboardFallback {
                    let fallbackResult = self.performSafeClipboardPaste(text: text)
                    continuation.resume(returning: fallbackResult)
                } else {
                    continuation.resume(returning: .failed("Direct AX injection unsupported for focused element"))
                }
            }
        }
    }

    // MARK: - Strategy 1: Direct AX Injection

    private func attemptDirectAXInjection(text: String) -> Bool {
        let systemWideElement = AXUIElementCreateSystemWide()

        var focusedApp: AnyObject?
        let appError = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedApplicationAttribute as CFString,
            &focusedApp
        )

        guard appError == .success, let appElement = focusedApp as! AXUIElement? else {
            return false
        }

        var focusedUIElement: AnyObject?
        let elemError = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedUIElement
        )

        guard elemError == .success, let targetElement = focusedUIElement as! AXUIElement? else {
            return false
        }

        // Check if value is settable
        var isSettable: DarwinBoolean = false
        let settableError = AXUIElementIsAttributeSettable(
            targetElement,
            kAXValueAttribute as CFString,
            &isSettable
        )

        if settableError == .success && isSettable.boolValue {
            // First check if there is an insertion point / selection to replace
            var selectedRangeValue: AnyObject?
            if AXUIElementCopyAttributeValue(targetElement, kAXSelectedTextRangeAttribute as CFString, &selectedRangeValue) == .success,
               let rangeVal = selectedRangeValue as! AXValue? {
                var range = CFRange()
                if AXValueGetValue(rangeVal, .cfRange, &range) {
                    // Try AXUIElementSetAttributeValue with selected text if supported
                    let nsText = text as CFTypeRef
                    if AXUIElementSetAttributeValue(targetElement, kAXSelectedTextAttribute as CFString, nsText) == .success {
                        return true
                    }
                }
            }

            // Fallback: append or replace kAXValueAttribute
            var currentValue: AnyObject?
            let getValError = AXUIElementCopyAttributeValue(targetElement, kAXValueAttribute as CFString, &currentValue)

            let finalString: String
            if getValError == .success, let existing = currentValue as? String {
                finalString = existing + (existing.isEmpty || existing.hasSuffix(" ") ? "" : " ") + text
            } else {
                finalString = text
            }

            let setResult = AXUIElementSetAttributeValue(
                targetElement,
                kAXValueAttribute as CFString,
                finalString as CFTypeRef
            )

            if setResult == .success {
                return true
            }
        }

        return false
    }

    // MARK: - Strategy 2: Safe Clipboard Paste

    private func performSafeClipboardPaste(text: String) -> InjectionResult {
        // Save existing clipboard state
        let originalChangeCount = pasteboard.changeCount
        let previousString = pasteboard.string(forType: .string)

        // Set transcribed text
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            return .failed("Failed to write to NSPasteboard")
        }

        // Post synthetic Cmd+V key event
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKeyCode: CGKeyCode = 0x09 // Virtual key code for 'v'

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            return .clipboardCopiedOnly
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        // Asynchronously restore original clipboard contents after app has accepted event
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(45)) { [weak self] in
            guard let self = self else { return }
            // Only restore if user hasn't made another copy operation in between
            if self.pasteboard.changeCount == originalChangeCount + 1 {
                self.pasteboard.clearContents()
                if let previous = previousString {
                    self.pasteboard.setString(previous, forType: .string)
                }
            }
        }

        return .clipboardSimulatedPaste
    }
}
