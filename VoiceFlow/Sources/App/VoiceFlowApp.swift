import SwiftUI

@main
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
            .holdToTalk: KeyChord(.control, .v)
        ])
        textPaster = TextPaster()
        meetingManager = MeetingManager()

        // Wire hotkey callbacks to coordinator
        hotkeyMonitor.onRecordingStart = {
            Task { await coordinator.beginRecording() }
        }
        hotkeyMonitor.onRecordingStop = {
            Task { await coordinator.finishRecording() }
        }

        // Wire transcription ready to text paster
        coordinator.onTranscriptionReady = { [weak textPaster] text in
            textPaster?.paste(text)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanelView()
                .environmentObject(appState)
                .environmentObject(settings)
                .environmentObject(coordinator)
                .task {
                    // Start hotkey monitoring when menu bar panel appears
                    let hasPermission = hotkeyMonitor.start()
                    if hasPermission {
                        print("[VoiceFlow] Hotkey monitor started")
                    } else {
                        print("[VoiceFlow] Hotkey monitor failed - accessibility permission required")
                    }
                }
        } label: {
            Image(systemName: appState.menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsPlaceholderView()
                .environmentObject(settings)
                .frame(width: 520, height: 420)
        }

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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Menu Bar Panel (placeholder; replaced by UI task)

struct MenuBarPanelView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var coordinator: DictationCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(appState.modelStatusDescription)
                .font(.callout)

            Text(PermissionManager.shared.summaryText)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Start Dictation") {
                    appState.startDictation()
                }
                .disabled(!appState.isReadyToDictate || appState.phase != .idle)

                Button("Stop Dictation") {
                    appState.stopDictation()
                }
                .disabled(appState.phase != .recording)
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
        .frame(width: 240)
        // Kick off model download / Whisper engine creation once the panel
        // first appears (idempotent inside the coordinator).
        .task {
            await coordinator.bootstrap()
        }
    }
}

// MARK: - Settings Placeholder

struct SettingsPlaceholderView: View {
    var body: some View {
        Text("Settings coming soon")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
