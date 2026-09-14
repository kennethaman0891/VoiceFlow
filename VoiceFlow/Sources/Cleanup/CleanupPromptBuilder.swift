import Foundation

// MARK: - CleanupPromptBuilder

/// Builds prompts for different cleanup operations.
final class CleanupPromptBuilder {
    static let shared = CleanupPromptBuilder()

    private init() {}

    // MARK: - Prompt Templates

    func buildForMode(_ mode: CleanupMode, text: String) -> String {
        let templates: [CleanupMode: String] = [
            .none: text,
            .fillers: buildFillerRemovalPrompt(text),
            .grammar: buildGrammarPrompt(text),
            .professional: buildProfessionalPrompt(text),
            .concise: buildConcisePrompt(text)
        ]

        return templates[mode] ?? text
    }

    // MARK: - Private Builders

    private func buildFillerRemovalPrompt(_ text: String) -> String {
        """
        Remove filler words and hesitant speech from this transcript. Filler words include:
        - um, uh, uhh, erm, err
        - like, you know, basically, actually
        - so, well, I mean
        - right, okay, yeah

        Rules:
        1. Remove standalone filler words
        2. Keep fillers that are part of the actual content (e.g., "like" in "it's like a ball")
        3. Preserve the original meaning
        4. Fix punctuation if needed
        5. Return ONLY the cleaned text, no explanations

        Original transcript:
        \(text)

        Cleaned text:
        """
    }

    private func buildGrammarPrompt(_ text: String) -> String {
        """
        Fix grammar, punctuation, and capitalization in this transcript. Make it read \
        naturally while preserving the speaker's voice and meaning.

        Rules:
        1. Fix subject-verb agreement
        2. Add proper punctuation (periods, commas, question marks)
        3. Capitalize sentences and proper nouns
        4. Fix common errors (their/there/they're, your/you're, etc.)
        5. Keep the informal tone if appropriate
        6. Return ONLY the corrected text

        Original transcript:
        \(text)

        Corrected text:
        """
    }

    private func buildProfessionalPrompt(_ text: String) -> String {
        """
        Rewrite this transcript in a professional business tone. Make it suitable for \
        meeting notes or official documentation.

        Rules:
        1. Use formal business language
        2. Remove casual expressions and slang
        3. Structure thoughts clearly
        4. Use complete sentences
        5. Maintain all key facts and decisions
        6. Return ONLY the professional version

        Original transcript:
        \(text)

        Professional version:
        """
    }

    private func buildConcisePrompt(_ text: String) -> String {
        """
        Make this transcript more concise and to the point. Remove redundancies and \
        shorten sentences without losing important information.

        Rules:
        1. Remove repetitive phrases
        2. Shorten overly long sentences
        3. Keep key facts, numbers, and decisions
        4. Maintain clarity
        5. Return ONLY the condensed text

        Original transcript:
        \(text)

        Concise version:
        """
    }
}
