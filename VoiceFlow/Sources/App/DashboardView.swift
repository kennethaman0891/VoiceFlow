import SwiftUI

/// Control surface for the live dictation pipeline: model, language, hotkey, and paste behavior.
struct DashboardView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var coordinator: DictationCoordinator
    @ObservedObject private var permissions = PermissionManager.shared

    private var selectedModelID: String {
        SpeechModelCatalog.whisperKitVariant(
            settingsName: settings.modelName,
            hardwareName: appState.hardwareProfile?.recommendedWhisperModel
        )
    }

    private var controlsLocked: Bool {
        appState.isRecording || appState.phase == .transcribing
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            statusColumn
                .frame(width: 250)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    modelSection
                    languageSection
                    dictationSection
                    historySection
                }
            }
        }
        .padding(20)
        .frame(minWidth: 900, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { permissions.refreshAll() }
    }

    private var statusColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("VoiceFlow")
                    .font(.title2.weight(.semibold))
                Text(statusLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(appState.modelStatusDescription)
                    .font(.caption)
                if case .downloading(let progress) = appState.modelStatus {
                    ProgressView(value: progress)
                }
            }

            if let hardware = appState.hardwareProfile {
                Text("\(hardware.chipName) · \(hardware.recommendedTier.rawValue)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            permissionRow("Microphone", granted: permissions.state.microphone) {
                permissions.requestMicrophone()
            }
            permissionRow("Accessibility", granted: permissions.state.accessibility) {
                permissions.requestAccessibility()
            }
            permissionRow("Input Monitoring", granted: permissions.state.inputMonitoring) {
                permissions.requestInputMonitoring()
            }

            Spacer(minLength: 12)

            Button(appState.isRecording ? "Stop" : "Hold to Talk") {
                Task {
                    if appState.isRecording {
                        await coordinator.finishRecording()
                    } else {
                        await coordinator.beginRecording(handsFree: false)
                    }
                }
            }
            .disabled(!appState.isReadyToDictate && !appState.isRecording)

            Button("Hands-Free") {
                Task { await coordinator.toggleHandsFree() }
            }
            .disabled(!appState.isReadyToDictate && !appState.isRecording)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
    }

    private var modelSection: some View {
        DashboardCard(title: "Speech model", systemImage: "waveform") {
            Text("English models are faster. Multilingual is what other languages use.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 10) {
                ForEach(SpeechModelCatalog.models) { model in
                    modelCard(model)
                }
            }
        }
    }

    private func modelCard(_ model: SpeechModelOption) -> some View {
        let selected = selectedModelID == model.id
        return Button {
            Task { await coordinator.selectModel(model.id) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(model.title)
                        .font(.headline)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(model.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                Text(model.size)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
            .background(
                selected ? Color.accentColor.opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(controlsLocked)
    }

    private var languageSection: some View {
        DashboardCard(title: "Language", systemImage: "globe") {
            Text(languageFootnote)
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(SpeechModelCatalog.languages) { language in
                    languageChip(language)
                }
            }
        }
    }

    private func languageChip(_ language: DictationLanguage) -> some View {
        let selected = settings.languageCode == language.code
        return Button {
            Task { await coordinator.selectLanguage(language.code) }
        } label: {
            Text(language.name)
                .font(.callout)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(
                    selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                    in: Capsule()
                )
                .overlay(
                    Capsule().stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(controlsLocked)
    }

    private var languageFootnote: String {
        if SpeechModelCatalog.isEnglishOnly(selectedModelID) {
            return "This model is English only. Choosing another language switches to Small Multilingual and downloads it once."
        }
        return "Auto-detect lets the multilingual model choose the language for each take."
    }

    private var dictationSection: some View {
        DashboardCard(title: "Dictation", systemImage: "keyboard") {
            Picker("Hotkey", selection: hotkeySelection) {
                ForEach(HotkeyMode.dashboardChoices) { mode in
                    Text(mode.menuLabel).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text("Double-tap the hotkey for hands-free. Escape cancels the take.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Paste into the focused field", isOn: $settings.autoPasteEnabled)
            Toggle("Sound when recording starts and finishes", isOn: $settings.soundFeedbackEnabled)
            Toggle("Save each take in history", isOn: $settings.historyEnabled)

            Picker("Cleanup", selection: $settings.cleanupMode) {
                Text(CleanupMode.none.rawValue).tag(CleanupMode.none)
                Text(CleanupMode.fillers.rawValue).tag(CleanupMode.fillers)
            }
            .pickerStyle(.segmented)
            Text("Filler removal runs on-device and strips um, uh, and hmm. Tone and grammar cleanup arrives with the local language model.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Ignore holds shorter than \(settings.minRecordingDuration, specifier: "%.1f")s")
                    .font(.callout)
                Slider(value: $settings.minRecordingDuration, in: 0.2...1.0, step: 0.1)
            }
        }
    }

    private var hotkeySelection: Binding<HotkeyMode> {
        Binding(
            get: { settings.hotkeyMode.dashboardValue },
            set: { mode in
                settings.hotkeyMode = mode
                coordinator.applyHotkey()
            }
        )
    }

    private var historySection: some View {
        DashboardCard(title: "Recent takes", systemImage: "clock") {
            if appState.transcriptionHistory.isEmpty {
                Text("Nothing dictated yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appState.transcriptionHistory.prefix(6)) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.text)
                            .font(.body)
                            .lineLimit(2)
                        Text(entry.date, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                }
                Button("Clear history") {
                    appState.clearHistory()
                }
            }
        }
    }

    private var statusLine: String {
        switch appState.phase {
        case .recording:
            return "Recording"
        case .handsFree:
            return "Hands-free"
        case .transcribing:
            return "Transcribing"
        case .success:
            return "Last take pasted"
        case .idle:
            if !permissions.state.microphone {
                return "Microphone permission needed"
            }
            if !permissions.state.accessibility {
                return "Accessibility permission needed to paste"
            }
            return "Hold \(settings.hotkeyMode.menuLabel) to talk"
        }
    }

    private func permissionRow(_ title: String, granted: Bool, request: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(granted ? Color.green : Color.orange)
            Text(title)
                .font(.callout)
            Spacer()
            if !granted {
                Button("Grant") { request() }
                    .controlSize(.small)
            }
        }
    }
}

private struct DashboardCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 16))
    }
}
