import Foundation
import Combine

// MARK: - Types

/// How dictation is triggered.
enum HotkeyMode: String, Codable {
    case globeKey       // Fn / Globe key
    case rightCommand   // Right Command key
    case controlV       // Control+V (Ghost Pepper style)
}

// MARK: - AppSettings

/// UserDefaults-backed user settings.
///
/// Every `@Published` property persists through `didSet` under a `"settings."`
/// prefixed key and is seeded from `UserDefaults` at init.
@MainActor
final class AppSettings: ObservableObject {

    private let defaults: UserDefaults

    // MARK: Keys

    private enum Key {
        static let hotkeyMode = "settings.hotkeyMode"
        static let languageCode = "settings.languageCode"
        static let modelName = "settings.modelName"
        static let autoPasteEnabled = "settings.autoPasteEnabled"
        static let soundFeedbackEnabled = "settings.soundFeedbackEnabled"
        static let historyEnabled = "settings.historyEnabled"
        static let minRecordingDuration = "settings.minRecordingDuration"
    }

    /// Downloadable English-only whisper.cpp models offered in Settings.
    static let availableModels: [(id: String, label: String, sizeLabel: String)] = [
        ("ggml-tiny.en", "Tiny (English) · Fastest", "~75 MB"),
        ("ggml-base.en", "Base (English) · Recommended", "~148 MB"),
        ("ggml-small.en", "Small (English)", "~470 MB"),
        ("ggml-medium.en", "Medium (English) · Best", "~1.5 GB"),
        ("ggml-large-v3", "Large v3 (Multilingual) · Production", "~3 GB")
    ]

    // MARK: Published settings

    @Published var hotkeyMode: HotkeyMode {
        didSet { defaults.set(hotkeyMode.rawValue, forKey: Key.hotkeyMode) }
    }

    /// English-first; the UI locks this for now.
    @Published var languageCode: String {
        didSet { defaults.set(languageCode, forKey: Key.languageCode) }
    }

    @Published var modelName: String {
        didSet { defaults.set(modelName, forKey: Key.modelName) }
    }

    @Published var autoPasteEnabled: Bool {
        didSet { defaults.set(autoPasteEnabled, forKey: Key.autoPasteEnabled) }
    }

    @Published var soundFeedbackEnabled: Bool {
        didSet { defaults.set(soundFeedbackEnabled, forKey: Key.soundFeedbackEnabled) }
    }

    @Published var historyEnabled: Bool {
        didSet { defaults.set(historyEnabled, forKey: Key.historyEnabled) }
    }

    /// Recordings shorter than this (seconds) are discarded as accidental taps.
    @Published var minRecordingDuration: Double {
        didSet { defaults.set(minRecordingDuration, forKey: Key.minRecordingDuration) }
    }

    // MARK: Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        defaults.register(defaults: [
            Key.hotkeyMode: HotkeyMode.globeKey.rawValue,
            Key.languageCode: "en",
            Key.modelName: "ggml-base.en",
            Key.autoPasteEnabled: true,
            Key.soundFeedbackEnabled: true,
            Key.historyEnabled: true,
            Key.minRecordingDuration: 0.3
        ])

        hotkeyMode = HotkeyMode(rawValue: defaults.string(forKey: Key.hotkeyMode) ?? "") ?? .globeKey
        languageCode = defaults.string(forKey: Key.languageCode) ?? "en"
        modelName = defaults.string(forKey: Key.modelName) ?? "ggml-base.en"
        autoPasteEnabled = defaults.bool(forKey: Key.autoPasteEnabled)
        soundFeedbackEnabled = defaults.bool(forKey: Key.soundFeedbackEnabled)
        historyEnabled = defaults.bool(forKey: Key.historyEnabled)
        minRecordingDuration = defaults.double(forKey: Key.minRecordingDuration)
    }
}
