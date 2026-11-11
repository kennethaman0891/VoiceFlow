import Foundation
import Combine

// MARK: - Types

/// How dictation is triggered.
enum HotkeyMode: String, Codable, CaseIterable, Identifiable {
    case control
    case optionSpace
    case rightCommand
    case globeKey
    case controlV

    var id: String { rawValue }

    /// Choices shown on the dashboard. Older stored values still decode.
    static let dashboardChoices: [HotkeyMode] = [.control, .optionSpace, .rightCommand]

    var dashboardValue: HotkeyMode {
        switch self {
        case .optionSpace:
            return .optionSpace
        case .rightCommand:
            return .rightCommand
        case .control, .globeKey, .controlV:
            return .control
        }
    }

    var menuLabel: String {
        switch dashboardValue {
        case .control:
            return "Control"
        case .optionSpace:
            return "Option+Space"
        case .rightCommand:
            return "Right Command"
        case .globeKey, .controlV:
            return "Control"
        }
    }

    var chord: KeyChord {
        switch dashboardValue {
        case .optionSpace:
            return .optionSpace
        case .rightCommand:
            return KeyChord(.rightCommand)
        case .control, .globeKey, .controlV:
            return .controlHold
        }
    }
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
        static let cleanupMode = "settings.cleanupMode"
    }

    /// WhisperKit models offered in Settings and the dashboard.
    static let availableModels: [(id: String, label: String, sizeLabel: String)] = SpeechModelCatalog.models.map {
        ($0.id, "\($0.title) · \($0.detail)", $0.size)
    }

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

    /// Offline cleanup. Filler removal is local. Other modes wait for the on-device LLM.
    @Published var cleanupMode: CleanupMode {
        didSet { defaults.set(cleanupMode.rawValue, forKey: Key.cleanupMode) }
    }

    // MARK: Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        defaults.register(defaults: [
            Key.hotkeyMode: HotkeyMode.control.rawValue,
            Key.languageCode: "en",
            Key.modelName: SpeechModelCatalog.defaultVariant,
            Key.autoPasteEnabled: true,
            Key.soundFeedbackEnabled: true,
            Key.historyEnabled: true,
            Key.minRecordingDuration: 0.3,
            Key.cleanupMode: CleanupMode.fillers.rawValue
        ])

        hotkeyMode = HotkeyMode(rawValue: defaults.string(forKey: Key.hotkeyMode) ?? "") ?? .control
        languageCode = defaults.string(forKey: Key.languageCode) ?? "en"
        modelName = defaults.string(forKey: Key.modelName) ?? SpeechModelCatalog.defaultVariant
        autoPasteEnabled = defaults.bool(forKey: Key.autoPasteEnabled)
        soundFeedbackEnabled = defaults.bool(forKey: Key.soundFeedbackEnabled)
        historyEnabled = defaults.bool(forKey: Key.historyEnabled)
        minRecordingDuration = defaults.double(forKey: Key.minRecordingDuration)
        cleanupMode = CleanupMode(rawValue: defaults.string(forKey: Key.cleanupMode) ?? "") ?? .fillers
    }
}
