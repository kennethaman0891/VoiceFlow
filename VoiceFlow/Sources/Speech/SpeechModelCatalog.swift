import Foundation

/// English WhisperKit models used for dictation.
///
/// `small.en` is the default. `tiny.en` is the fast option for low-memory Macs
/// and for an explicit user choice. Legacy ggml filenames still map here so
/// older settings do not point at a model this slice cannot load.
struct DictationLanguage: Identifiable, Hashable, Sendable {
    let code: String
    let name: String
    var id: String { code }
}

struct SpeechModelOption: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let detail: String
    let size: String
    let englishOnly: Bool
}

enum SpeechModelCatalog {
    static let tinyEnglish = "tiny.en"
    static let smallEnglish = "small.en"
    static let multilingual = "small"
    static let automaticLanguage = "auto"
    static let defaultVariant = smallEnglish

    static let models: [SpeechModelOption] = [
        SpeechModelOption(
            id: tinyEnglish,
            title: "Tiny",
            detail: "Fastest English dictation",
            size: "~75 MB",
            englishOnly: true
        ),
        SpeechModelOption(
            id: smallEnglish,
            title: "Small",
            detail: "Default English accuracy",
            size: "~466 MB",
            englishOnly: true
        ),
        SpeechModelOption(
            id: multilingual,
            title: "Small Multilingual",
            detail: "Required for other languages and auto-detect",
            size: "~466 MB",
            englishOnly: false
        )
    ]

    static let languages: [DictationLanguage] = [
        DictationLanguage(code: "en", name: "English"),
        DictationLanguage(code: "es", name: "Spanish"),
        DictationLanguage(code: "fr", name: "French"),
        DictationLanguage(code: "de", name: "German"),
        DictationLanguage(code: "it", name: "Italian"),
        DictationLanguage(code: "pt", name: "Portuguese"),
        DictationLanguage(code: "nl", name: "Dutch"),
        DictationLanguage(code: "pl", name: "Polish"),
        DictationLanguage(code: "ru", name: "Russian"),
        DictationLanguage(code: "uk", name: "Ukrainian"),
        DictationLanguage(code: "tr", name: "Turkish"),
        DictationLanguage(code: "ar", name: "Arabic"),
        DictationLanguage(code: "hi", name: "Hindi"),
        DictationLanguage(code: "zh", name: "Chinese"),
        DictationLanguage(code: "ja", name: "Japanese"),
        DictationLanguage(code: "ko", name: "Korean"),
        DictationLanguage(code: automaticLanguage, name: "Auto-detect")
    ]

    static func whisperKitVariant(settingsName: String, hardwareName: String?) -> String {
        switch canonical(settingsName) {
        case tinyEnglish, smallEnglish, multilingual:
            return canonical(settingsName)
        default:
            break
        }
        if canonical(hardwareName ?? "") == tinyEnglish {
            return tinyEnglish
        }
        return defaultVariant
    }

    static func isEnglishOnly(_ modelID: String) -> Bool {
        let variant = canonical(modelID)
        return variant == tinyEnglish || variant == smallEnglish
    }

    /// Choosing an English-only model forces English.
    static func modelChoice(_ model: String, keeping language: String) -> (model: String, language: String) {
        let variant = whisperKitVariant(settingsName: model, hardwareName: nil)
        if isEnglishOnly(variant) {
            return (variant, "en")
        }
        return (variant, language)
    }

    /// Choosing a non-English language moves an English-only model to multilingual.
    static func languageChoice(_ language: String, keeping model: String) -> (model: String, language: String) {
        let variant = whisperKitVariant(settingsName: model, hardwareName: nil)
        if language != "en" && isEnglishOnly(variant) {
            return (multilingual, language)
        }
        return (variant, language)
    }

    static func languageName(for code: String) -> String {
        languages.first { $0.code == code }?.name ?? code
    }

    static func ggmlName(for variant: String) -> String {
        switch variant {
        case tinyEnglish:
            return "ggml-tiny.en"
        case multilingual:
            return "ggml-small"
        default:
            return "ggml-small.en"
        }
    }

    private static func canonical(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("tiny") { return tinyEnglish }
        if lower.contains("small.en") { return smallEnglish }
        if lower == "small" || lower == "ggml-small" { return multilingual }
        return lower
    }
}
