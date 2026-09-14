import Foundation

// MARK: - TextPostProcessor
//
// Deterministic, dependency-free English cleanup for raw whisper.cpp output.
//
/// English post-processing for dictation transcripts.
///
/// Pipeline: whitespace normalization → optional filler removal → standalone
/// lowercase "i" repair → sentence capitalization → terminal punctuation.
///
/// Examples:
///
///     process("  hello   world ")                       // "Hello world."
///     process("um i think  uh she said hi")             // "I think she said hi."
///     process("let's go. are you ready? yes")           // "Let's go. Are you ready? Yes."
///     process("um, uh, testing one two")                // "Testing one two."
///     process("she is here and her book")               // "She is here and her book." (no false hits)
///     process("i said umm ok")                          // "I said ok."
enum TextPostProcessor {

    /// Standalone filler tokens (case-insensitive, word-bounded). An attached
    /// trailing comma/period is consumed too so removal doesn't leave ", ,".
    private static let fillerRegex = try! NSRegularExpression(
        pattern: "\\b(?:um+|uh+|erm|err?|ah+|ahem|hmm+|hm+)\\b[,.]?",
        options: [.caseInsensitive])

    private static let standaloneLowercaseIRegex = try! NSRegularExpression(
        pattern: "\\bi\\b")

    private static let multiSpaceRegex = try! NSRegularExpression(
        pattern: "[ \\t]{2,}")

    private static let spaceBeforePunctuationRegex = try! NSRegularExpression(
        pattern: " +([,.!?;:])")

    // MARK: Entry point

    static func process(_ raw: String, removeFillers: Bool = true) -> String {
        var text = collapseWhitespace(in: raw)

        if removeFillers {
            text = removeFillerTokens(from: text)
            text = collapseWhitespace(in: text)
        }

        text = fixStandaloneLowercaseI(in: text)
        text = capitalizeSentences(in: text)
        text = ensureTerminalPunctuation(on: text)
        return text
    }

    // MARK: Steps

    /// Trims edges, converts newlines to spaces, collapses repeated spaces.
    static func collapseWhitespace(in text: String) -> String {
        var result = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        result = multiSpaceRegex.stringByReplacingMatches(
            in: result, range: NSRange(result.startIndex..., in: result),
            withTemplate: " ")

        // "word ," → "word,"
        result = spaceBeforePunctuationRegex.stringByReplacingMatches(
            in: result, range: NSRange(result.startIndex..., in: result),
            withTemplate: "$1")

        return result
    }

    /// Removes standalone fillers ("um", "uhh", "erm", "hmm", …) without
    /// touching words that merely contain those letters ("her" stays intact).
    static func removeFillerTokens(from text: String) -> String {
        fillerRegex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text),
            withTemplate: "")
    }

    /// Repairs a standalone lowercase "i" to uppercase "I"
    /// (covers contractions: "i'm" → "I'm"; leaves "hi"/"in" alone).
    static func fixStandaloneLowercaseI(in text: String) -> String {
        standaloneLowercaseIRegex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text),
            withTemplate: "I")
    }

    /// Uppercases the first letter of each sentence. Sentences are delimited
    /// by '.', '!', or '?'; the delimiters themselves are preserved as-is.
    static func capitalizeSentences(in text: String) -> String {
        var output = ""
        output.reserveCapacity(text.utf16.count)

        var capitalizeNext = true
        for character in text {
            if capitalizeNext, character.isLetter {
                output.append(contentsOf: String(character).uppercased())
                capitalizeNext = false
            } else {
                output.append(character)
                if character == "." || character == "!" || character == "?" {
                    capitalizeNext = true
                }
            }
        }
        return output
    }

    /// Appends "." when the text ends with an alphanumeric character.
    static func ensureTerminalPunctuation(on text: String) -> String {
        guard let last = text.last,
              CharacterSet.alphanumerics.contains(last.unicodeScalars.first ?? " ")
        else { return text }
        return text + "."
    }
}
