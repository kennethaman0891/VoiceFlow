import Foundation
import Combine
import AVFoundation
import ApplicationServices
import CoreGraphics
import AppKit

// MARK: - Types

struct PermissionState {
    var microphone: Bool = false
    var accessibility: Bool = false
    var inputMonitoring: Bool = false
}

// MARK: - PermissionManager

/// Tracks and requests the three macOS permissions VoiceFlow needs:
/// microphone, Accessibility (AX) and Input Monitoring (event listening).
///
/// `refreshAll()` runs at init; the UI should call it again when its panel
/// opens/refreshes so statuses stay current (System Settings changes are not
/// pushed to us).
@MainActor
final class PermissionManager: ObservableObject {

    static let shared = PermissionManager()

    @Published private(set) var state = PermissionState()

    private init() {
        refreshAll()
    }

    // MARK: Refresh

    func refreshAll() {
        state.microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        state.accessibility = AXIsProcessTrusted()
        state.inputMonitoring = CGPreflightListenEventAccess()
    }

    // MARK: Requests

    /// Prompts for Accessibility trust if needed and opens the relevant
    /// System Settings pane so the user can enable it.
    func requestAccessibility() {
        // Value of kAXTrustedCheckOptionPrompt per AXUIElement.h; spelled as a
        // literal because the imported global isn't Sendable-annotated and
        // referencing it trips Swift 6 strict concurrency.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        state.accessibility = AXIsProcessTrustedWithOptions(options)

        if !state.accessibility {
            openSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }

    /// Requests Input Monitoring (global event listening) and opens the
    /// relevant System Settings pane if not yet granted.
    func requestInputMonitoring() {
        state.inputMonitoring = CGRequestListenEventAccess()

        if !state.inputMonitoring {
            openSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        }
    }

    /// Prompts for microphone access (no-op dialog-wise if already decided).
    func requestMicrophone() {
        Task { @MainActor in
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            self.state.microphone = granted
        }
    }

    // MARK: Summary

    var summaryText: String {
        "Permissions: Mic \(symbol(state.microphone)) · Accessibility \(symbol(state.accessibility)) · Input Monitoring \(symbol(state.inputMonitoring))"
    }

    private func symbol(_ granted: Bool) -> String {
        granted ? "✓" : "✗"
    }

    private func openSettingsPane(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
