import SwiftUI

struct VoiceFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState: AppState
    @StateObject private var settings: AppSettings
    // Multi-language STT/TTS agent surface (task: Speech-framework pipeline)
    @StateObject private var voiceState = VoiceFlowState()

    /// Owns the dictation pipeline: model bootstrap, audio capture,
    /// transcription and post-processing. Drives AppState via its hooks;
    /// views that need to trigger it receive it as an environment object.
    private let coordinator: DictationCoordinator
    private let hotkeyMonitor: HotkeyMonitor
    private let textPaster: TextPaster
    private let meetingManager: MeetingManager

    init() {
        // Constructed together so the StateObjects and the pipeline share the
        // exact same instances.
        let appState = AppState()
        let settings = AppSettings()

        _appState = StateObject(wrappedValue: appState)
        _settings = StateObject(wrappedValue: settings)
        coordinator = DictationCoordinator(appState: appState, settings: settings)
        hotkeyMonitor = HotkeyMonitor(bindings: [
            .holdToTalk: .controlHold
        ])
        textPaster = TextPaster()
        meetingManager = MeetingManager()

        // Wire hotkey callbacks to coordinator
        let coordinatorRef = coordinator
        let hotkeyMonitorRef = hotkeyMonitor

        hotkeyMonitor.onRecordingStart = { @Sendable in
            Task { @MainActor in await coordinatorRef.beginRecording(handsFree: false) }
        }
        hotkeyMonitor.onRecordingStop = { @Sendable in
            Task { @MainActor in
                await coordinatorRef.finishRecording()
                hotkeyMonitorRef.setHandsFreeState(appState.isHandsFree)
            }
        }
        hotkeyMonitor.onHandsFreeToggle = { @Sendable in
            Task { @MainActor in
                await coordinatorRef.toggleHandsFree()
                hotkeyMonitorRef.setHandsFreeState(appState.isHandsFree)
            }
        }
        hotkeyMonitor.onRecordingCancel = { @Sendable in
            Task { @MainActor in
                await coordinatorRef.cancelRecording()
                hotkeyMonitorRef.setHandsFreeState(false)
            }
        }
        coordinator.onHandsFreeChanged = { @Sendable active in
            hotkeyMonitorRef.setHandsFreeState(active)
        }
        coordinator.onHotkeyBindingChange = { chord in
            hotkeyMonitorRef.updateBindings([.holdToTalk: chord])
        }
        coordinator.applyHotkey()

        // Configure Handy floating HUD overlay
        FloatingHUDController.shared.configure(
            appState: appState,
            onToggle: {
                Task { @MainActor in await coordinatorRef.finishRecording() }
            },
            onCancel: {
                Task { @MainActor in await coordinatorRef.cancelRecording() }
            }
        )

        // Wire transcription ready to text paster (non-destructive auto-paste)
        coordinator.onTranscriptionReady = { [weak textPaster] text in
            Task { @MainActor in
                _ = await textPaster?.paste(text)
            }
        }

        // Start hotkey monitoring (non-async call)
        let hasPermission = hotkeyMonitor.start()
        if hasPermission {
            print("[VoiceFlow] Hotkey monitor started (Option+Space / Double-Tap)")
        } else {
            print("[VoiceFlow] Hotkey monitor failed - accessibility permission required")
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanelView()
                .environmentObject(appState)
                .environmentObject(settings)
                .environmentObject(coordinator)
        } label: {
            MenuBarStatusLabel(appState: appState)
                .task { await coordinator.bootstrap() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            DashboardView()
                .environmentObject(appState)
                .environmentObject(settings)
                .environmentObject(coordinator)
        }

        Window("Dashboard", id: "dashboard") {
            DashboardView()
                .environmentObject(appState)
                .environmentObject(settings)
                .environmentObject(coordinator)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 980, height: 700)

        Window("VoiceFlow Agent", id: "agent") {
            RootView()
                .environmentObject(voiceState)
                .frame(minWidth: 860, idealWidth: 980, minHeight: 560, idealHeight: 640)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 980, height: 640)

        Window("Meetings", id: "meetings") {
            MeetingListView()
                .environmentObject(meetingManager)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 900, height: 600)

        Window("History", id: "history") {
            HistoryPlaceholderView()
                .environmentObject(appState)
        }
        .windowResizability(.contentSize)
    }
}

@main
struct VoiceFlowMain {
    static func main() {
        VoiceFlowApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Menu Bar Panel (placeholder; replaced by UI task)

struct MenuBarStatusLabel: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var permissions = PermissionManager.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: iconName)
            .task {
                guard CommandLine.arguments.contains("--dashboard") else { return }
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }
    }

    private var iconName: String {
        if appState.phase == .idle,
           !permissions.state.microphone || !permissions.state.accessibility {
            return "exclamationmark.circle"
        }
        return appState.menuBarIcon
    }
}

struct MenuBarPanelView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var coordinator: DictationCoordinator
    @ObservedObject private var permissions = PermissionManager.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(statusLine)
                .font(.callout)

            Text(appState.modelStatusDescription)
                .font(.callout)

            if let hardware = appState.hardwareProfile {
                VStack(alignment: .leading, spacing: 2) {
                    Text(hardware.chipName)
                        .font(.caption)
                        .fontWeight(.medium)
                    Text("\(hardware.recommendedTier.rawValue)")
                        .font(.caption2)
                        .foregroundStyle(.cyan)
                }
            }

            Text(permissions.summaryText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !permissions.state.microphone {
                Button("Grant Microphone") {
                    permissions.requestMicrophone()
                }
            }
            if !permissions.state.accessibility {
                Button("Grant Accessibility") {
                    permissions.requestAccessibility()
                }
            }

            HStack(spacing: 8) {
                Button("Hands-Free") {
                    Task { await coordinator.toggleHandsFree() }
                }
                .disabled(!appState.isReadyToDictate)

                if appState.isRecording {
                    Button("Stop") {
                        Task { await coordinator.finishRecording() }
                    }
                } else {
                    Button("Hold to Talk") {
                        Task { await coordinator.beginRecording(handsFree: false) }
                    }
                    .disabled(!appState.isReadyToDictate)
                }
            }

            Button("Dashboard") {
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }

            Button("Open Agent Window") {
                openWindow(id: "agent")
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider()

            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }

            Button("Quit VoiceFlow") {
                NSApp.terminate(nil)
            }
        }
        .padding()
        .frame(width: 260)
        .task {
            permissions.refreshAll()
            await coordinator.bootstrap()
        }
    }

    private var statusLine: String {
        switch appState.phase {
        case .recording:
            return "Recording…"
        case .handsFree:
            return "Hands-free…"
        case .transcribing:
            return "Transcribing…"
        case .success:
            return "Pasted"
        case .idle:
            if !permissions.state.microphone {
                return "Microphone permission needed"
            }
            if !permissions.state.accessibility {
                return "Accessibility permission needed"
            }
            return "Hold \(settings.hotkeyMode.menuLabel) to talk"
        }
    }
}

// MARK: - History Placeholder

struct HistoryPlaceholderView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if appState.transcriptionHistory.isEmpty {
                Text("No transcriptions yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(appState.transcriptionHistory) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.text)
                            .font(.body)
                        Text(entry.date, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
    }
}

// MARK: - Main Agent Window (multi-language STT/TTS surface)

struct RootView: View {
    @EnvironmentObject var state: VoiceFlowState
    @StateObject private var meetingManager = MeetingManager.shared

    var body: some View {
        NavigationSplitView {
            List(selection: $state.selectedTab) {
                ForEach(VoiceFlowState.Tab.allCases, id: \.self) { tab in
                    NavigationLink(value: tab) {
                        Label(tab.rawValue, systemImage: icon(for: tab))
                    }
                }

                // Meeting section
                Section("Meetings") {
                    NavigationLink(value: VoiceFlowState.Tab.meetings) {
                        Label("All Meetings", systemImage: "calendar")
                    }

                    Button(action: {
                        if !meetingManager.isRecording {
                            Task { await meetingManager.startMeeting() }
                        } else {
                            Task { await meetingManager.stopMeeting() }
                        }
                    }) {
                        Label(
                            meetingManager.isRecording ? "Stop Meeting" : "New Meeting",
                            systemImage: meetingManager.isRecording ? "stop.circle" : "plus.circle"
                        )
                    }
                    .foregroundColor(meetingManager.isRecording ? .red : .blue)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if let folder = WebsiteLocator.folderURL {
                            NSWorkspace.shared.open(folder)
                        }
                    } label: {
                        Label("Open Website Folder", systemImage: "folder")
                    }
                    .disabled(WebsiteLocator.folderURL == nil)
                    .help("Open Website folder in Finder")
                }
            }
        } detail: {
            switch state.selectedTab {
            case .agent: VoiceAgentView()
            case .website: WebsiteView()
            case .embed: EmbedCodeView()
            case .meetings: MeetingListView()
            }
        }
        .toolbarBackground(.visible, for: .windowToolbar)
    }

    private func icon(for tab: VoiceFlowState.Tab) -> String {
        switch tab {
        case .agent: return "mic.circle.fill"
        case .website: return "globe"
        case .embed: return "curlybraces"
        case .meetings: return "calendar"
        }
    }
}
