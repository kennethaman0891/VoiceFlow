import Foundation

// MARK: - CleanupMode

enum CleanupMode: String, CaseIterable, Identifiable {
    case none = "None"
    case fillers = "Remove Fillers"
    case grammar = "Improve Grammar"
    case professional = "Professional Tone"
    case concise = "Be Concise"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .none: return "No changes"
        case .fillers: return "Remove um, uh, like, you know"
        case .grammar: return "Fix grammar and punctuation"
        case .professional: return "Make it sound professional"
        case .concise: return "Shorten and clarify"
        }
    }
}

// MARK: - CleanupResult

struct CleanupResult {
    let original: String
    let cleaned: String
    let mode: CleanupMode
    let latency: TimeInterval
    let success: Bool
}

// MARK: - TextCleanupManager

/// Manages text cleanup operations using either regex or local LLM.
@MainActor
final class TextCleanupManager: ObservableObject {
    static let shared = TextCleanupManager()

    @Published var lastResult: CleanupResult?
    @Published var isProcessing = false

    private let ollamaClient = OllamaClient.shared
    private let settings = AppSettings()

    private init() {}

    // MARK: - Public API

    /// Clean up transcript text using the configured mode.
    func clean(_ text: String, mode: CleanupMode = .fillers) async -> CleanupResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        var result: String

        switch mode {
        case .none:
            result = text
        case .fillers, .grammar, .professional, .concise:
            result = await cleanWithLLM(text, mode: mode) ?? TextPostProcessor.process(text)
        }

        let latency = CFAbsoluteTimeGetCurrent() - startTime

        let cleanupResult = CleanupResult(
            original: text,
            cleaned: result,
            mode: mode,
            latency: latency,
            success: true
        )

        lastResult = cleanupResult
        return cleanupResult
    }

    /// Clean up meeting transcript segments.
    func cleanMeeting(_ transcript: MeetingTranscript) async {
        for i in transcript.segments.indices {
            let cleaned = await clean(transcript.segments[i].text, mode: .professional)
            transcript.segments[i].text = cleaned.cleaned
        }
    }

    // MARK: - Private

    private func cleanWithLLM(_ text: String, mode: CleanupMode) async -> String? {
        guard let ollamaHost = ProcessInfo.processInfo.environment["OLLAMA_HOST"],
              !ollamaHost.isEmpty else {
            return nil // Fallback to regex
        }

        let prompt = buildPrompt(for: mode, text: text)

        do {
            let response = try await ollamaClient.generate(
                model: "qwen2.5:7b",
                prompt: prompt,
                text: ""
            )
            return response.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            print("[TextCleanupManager] LLM cleanup failed: \(error)")
            return nil
        }
    }

    private func buildPrompt(for mode: CleanupMode, text: String) -> String {
        let baseInstructions: [CleanupMode: String] = [
            .fillers: """
                Remove filler words (um, uh, like, you know, basically, actually, etc.) \
                from the following transcript. Keep the meaning intact. Return only the \
                cleaned text without any explanation.
                """,
            .grammar: """
                Fix grammar, punctuation, and capitalization in the following transcript. \
                Make it read naturally while preserving the original meaning. Return only \
                the corrected text.
                """,
            .professional: """
                Rewrite the following transcript in a professional tone. Use proper \
                business language, fix grammar, and make it clear and concise. Return \
                only the rewritten text.
                """,
            .concise: """
                Make the following transcript more concise. Remove redundancies and \
                shorten sentences while keeping the key information. Return only the \
                condensed text.
                """
        ]

        let instructions = baseInstructions[mode] ?? baseInstructions[.fillers]!

        return """
            \(instructions)

            Transcript:
            \(text)

            Cleaned version:
            """
    }
}
