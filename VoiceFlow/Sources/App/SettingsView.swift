import SwiftUI

// MARK: - SettingsView

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var hotkeyModifiers: [String] = []
    @State private var hotkeyKey: String = "V"
    @State private var showPermissionAlert = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Hotkey Settings
                SettingsSection(title: "Hotkey", icon: "keyboard") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Hold to activate:")
                                .font(.subheadline)
                            Spacer()
                            HStack(spacing: 4) {
                                ForEach(hotkeyModifiers, id: \.self) { modifier in
                                    Text(modifier)
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.blue.opacity(0.2))
                                        .cornerRadius(4)
                                }
                                Text("+")
                                    .foregroundStyle(.secondary)
                                Text(hotkeyKey)
                                    .font(.caption)
                                    .bold()
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.gray.opacity(0.2))
                                    .cornerRadius(4)
                            }
                        }

                        Text("Press Control+V to start dictation. Release to transcribe and paste.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Model Settings
                SettingsSection(title: "Speech Model", icon: "waveform") {
                    Picker("Model", selection: $settings.modelName) {
                        ForEach(AppSettings.availableModels, id: \.id) { model in
                            Text("\(model.label) (\(model.sizeLabel))")
                                .tag(model.id)
                        }
                    }
                    .pickerStyle(.menu)

                    Text("Larger models are more accurate but slower and use more memory.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Audio Settings
                SettingsSection(title: "Audio", icon: "mic") {
                    Toggle("Auto-paste to clipboard", isOn: $settings.autoPasteEnabled)
                    Toggle("Sound feedback", isOn: $settings.soundFeedbackEnabled)
                    Toggle("Save history", isOn: $settings.historyEnabled)
                }

                // Cleanup Settings
                SettingsSection(title: "Text Cleanup", icon: "wand.and.stars") {
                    Picker("Cleanup Mode", selection: /* TODO: bind to settings */ .constant(.fillers)) {
                        ForEach(CleanupMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)

                    Text("LLM cleanup requires Ollama running locally.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Privacy
                SettingsSection(title: "Privacy", icon: "shield") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("All processing happens on your device")
                        }
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("No audio is sent to cloud APIs (unless using Groq streaming)")
                        }
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Meeting recordings saved locally only")
                        }
                    }
                }

                // About
                SettingsSection(title: "About", icon: "info.circle") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("VoiceFlow - On-device speech recognition")
                            .font(.headline)
                        Text("Version 1.0.0")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Link("GitHub Repository", destination: URL(string: "https://github.com/matthartman/ghost-pepper")!)
                            .font(.caption)
                    }
                }
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 400)
        .onAppear {
            updateHotkeyDisplay()
        }
    }

    // MARK: - Private

    private func updateHotkeyDisplay() {
        // In production, read actual key codes from system
        hotkeyModifiers = ["Control"]
        hotkeyKey = "V"
    }
}

// MARK: - SettingsSection

struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(.primary)
                Text(title)
                    .font(.headline)
            }
            content()
        }
        .padding()
        .background(Color(.windowBackgroundColor))
        .cornerRadius(12)
    }
}
