import Foundation

// MARK: - MeetingSummaryGenerator

/// Generates meeting summaries using local LLM (Ollama) or fallback to simple extraction.
@MainActor
final class MeetingSummaryGenerator {
    static let shared = MeetingSummaryGenerator()

    private let ollamaClient = OllamaClient.shared

    /// Maximum characters per chunk sent to the LLM (~1500 tokens ≈ 6000 chars).
    private let chunkCharLimit = 5000

    static let defaultChunkPrompt = """
    Summarize the following meeting excerpt. Output concise bullet points organized by topic. \
    Include key facts, decisions, numbers, names, and dates. Be brief.
    """

    static let defaultFinalPrompt = """
    You are summarizing a meeting. You will receive a transcript and optionally the user's own notes \
    taken during the meeting. Read both carefully, then produce a structured summary organized by topic.

    Rules:
    - If the user wrote notes, treat them as a guide — they highlight what mattered most. Ensure those topics are covered prominently and expand on them with details from the transcript.
    - Use ### headings for each major topic discussed (e.g., "### Product Update", "### Hiring Plan", "### Q3 Budget")
    - Under each topic, use concise bullet points capturing key facts, decisions, numbers, names, and dates
    - Include a "### Next Steps" section at the end with any action items or follow-ups mentioned, using checkbox format: - [ ] Task — Owner
    - If the meeting is a 1:1 or introductory call, organize by the person/company discussed and what was learned
    - If the meeting is a group discussion or brainstorm, organize by the themes that emerged
    - Do NOT use generic headings like "Discussion Points" or "Key Takeaways" — use specific topic names from the actual conversation
    - Do NOT include filler, pleasantries, or off-topic chatter
    - Keep bullets factual and specific
    - Write in present tense for facts, past tense for what happened
    """

    private init() {}

    /// Generate a full summary for a completed meeting transcript.
    func generateSummary(for transcript: MeetingTranscript) async -> String? {
        let segments = transcript.segments
        guard !segments.isEmpty else { return nil }

        // Build the full transcript text
        let fullText = segments.map { segment in
            "[\(segment.formattedTimestamp)] \(segment.speaker.displayName): \(segment.text)"
        }.joined(separator: "\n")

        // Split into chunks
        let chunks = splitIntoChunks(fullText)

        // Include user notes if available
        let notesText = transcript.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesPrefix = notesText.isEmpty ? "" : "User's notes during the meeting:\n\n\(notesText)\n\n"

        do {
            if chunks.count == 1 {
                // Short meeting — summarize directly
                let input = "\(notesPrefix)Meeting transcript:\n\n\(chunks[0])"
                return await runLLM(text: input, prompt: MeetingSummaryGenerator.defaultFinalPrompt)
            }

            // Multi-chunk: summarize each chunk, then combine
            var chunkSummaries: [String] = []
            for (i, chunk) in chunks.enumerated() {
                let input = "Meeting transcript (part \(i + 1) of \(chunks.count)):\n\n\(chunk)"
                if let summary = await runLLM(text: input, prompt: MeetingSummaryGenerator.defaultChunkPrompt) {
                    chunkSummaries.append(summary)
                }
            }

            guard !chunkSummaries.isEmpty else { return nil }

            // Combine chunk summaries into final summary
            let combined = chunkSummaries.joined(separator: "\n\n---\n\n")
            let input = "\(notesPrefix)Summary of meeting sections:\n\n\(combined)"
            return await runLLM(text: input, prompt: MeetingSummaryGenerator.defaultFinalPrompt)

        } catch {
            print("[MeetingSummaryGenerator] Failed to generate summary: \(error)")
            return generateFallbackSummary(for: transcript, fullText: fullText)
        }
    }

    // MARK: - Private

    private func splitIntoChunks(_ text: String) -> [String] {
        let chars = Array(text)
        var chunks: [String] = []
        var currentChunk: [Character] = []
        var charCount = 0

        for char in chars {
            currentChunk.append(char)
            charCount += 1

            if charCount >= chunkCharLimit || char == "\n" && charCount > chunkCharLimit / 2 {
                chunks.append(String(currentChunk))
                currentChunk = []
                charCount = 0
            }
        }

        if !currentChunk.isEmpty {
            chunks.append(String(currentChunk))
        }

        return chunks
    }

    private func runLLM(text: String, prompt: String) async -> String? {
        do {
            let result = try await ollamaClient.generate(
                model: "qwen2.5:7b",
                prompt: prompt,
                text: text
            )
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            print("[MeetingSummaryGenerator] Ollama generation failed: \(error)")
            return nil
        }
    }

    /// Fallback summary when LLM is unavailable - extracts key info from transcript.
    private func generateFallbackSummary(for transcript: MeetingTranscript, fullText: String) -> String {
        var summary = "## Summary\n\n"
        summary += "**Participants:** \(transcript.segments.map { $0.speaker.displayName }.unique().joined(separator: ", "))\n\n"

        // Extract potential action items
        let actionItems = extractActionItems(from: fullText)
        if !actionItems.isEmpty {
            summary += "### Action Items\n\n"
            for item in actionItems.prefix(5) {
                summary += "- [ ] \(item)\n"
            }
            summary += "\n"
        }

        // Extract key topics
        let topics = extractTopics(from: fullText)
        if !topics.isEmpty {
            summary += "### Topics Discussed\n\n"
            for topic in topics.prefix(5) {
                summary += "- \(topic)\n"
            }
        }

        return summary
    }

    private func extractActionItems(from text: String) -> [String] {
        let patterns = [
            "action item",
            "follow up",
            "need to",
            "should",
            "will do",
            "task",
            "next steps"
        ]

        var items: [String] = []
        let lowerText = text.lowercased()

        for pattern in patterns {
            if lowerText.contains(pattern) {
                // Simple extraction - in production, use NLP
                let sentences = text.split(separator: ".")
                for sentence in sentences {
                    if sentence.lowercased().contains(pattern) {
                        items.append(String(sentence).trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
            }
        }

        return items
    }

    private func extractTopics(from text: String) -> [String] {
        // Simple keyword-based topic extraction
        let commonTopics = [
            "budget", "revenue", "sales", "product", "roadmap",
            "hiring", "team", "deadline", "milestone", "quarter"
        ]

        var topics: [String] = []
        let lowerText = text.lowercased()

        for topic in commonTopics {
            if lowerText.contains(topic) {
                topics.append(topic.capitalizingFirstLetter())
            }
        }

        return topics
    }
}

// MARK: - OllamaClient

/// Thin wrapper for Ollama API calls.
final class OllamaClient: @unchecked Sendable {
    static let shared = OllamaClient()

    private let baseURL = ProcessInfo.processInfo.environment["OLLAMA_HOST"] ?? "http://localhost:11434"

    private init() {}

    func generate(model: String, prompt: String, text: String) async throws -> String {
        let url = URL(string: "\(baseURL)/api/generate")!
        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "context": text
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw OllamaError.requestFailed
        }

        struct Response: Decodable {
            let response: String
        }

        let result = try JSONDecoder().decode(Response.self, from: data)
        return result.response
    }
}

enum OllamaError: Error, LocalizedError {
    case requestFailed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .requestFailed: return "Ollama request failed"
        case .invalidResponse: return "Invalid response from Ollama"
        }
    }
}
