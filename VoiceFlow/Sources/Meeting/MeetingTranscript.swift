import Foundation

// MARK: - SpeakerLabel

enum SpeakerLabel: Equatable, Codable {
    case me
    case remote(name: String?)

    var displayName: String {
        switch self {
        case .me: return "You"
        case .remote(let name): return name ?? "Speaker"
        }
    }
}

// MARK: - TranscriptSegment

struct TranscriptSegment: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let formattedTimestamp: String
    let speaker: SpeakerLabel
    let text: String
    let duration: TimeInterval

    init(id: UUID = UUID(), timestamp: Date = Date(), formattedTimestamp: String? = nil, speaker: SpeakerLabel, text: String, duration: TimeInterval) {
        self.id = id
        self.timestamp = timestamp
        self.formattedTimestamp = formattedTimestamp ?? Self.formatTimestamp(timestamp)
        self.speaker = speaker
        self.text = text
        self.duration = duration
    }

    static func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    static func == (lhs: TranscriptSegment, rhs: TranscriptSegment) -> Bool {
        return lhs.id == rhs.id && lhs.text == rhs.text && lhs.speaker == rhs.speaker
    }
}

// MARK: - MeetingTranscript

/// Data model for a single meeting transcription session.
final class MeetingTranscript: ObservableObject, Identifiable, Codable {
    let sessionID: UUID
    let meetingName: String
    let startDate: Date
    @Published var segments: [TranscriptSegment] = []
    @Published var notes: String = ""
    @Published var summary: String?
    @Published var isComplete: Bool = false

    private enum CodingKeys: CodingKey {
        case sessionID, meetingName, startDate, segments, notes, summary, isComplete
    }

    init(meetingName: String) {
        self.sessionID = UUID()
        self.meetingName = meetingName
        self.startDate = Date()
    }

    func addSegment(_ segment: TranscriptSegment) {
        segments.append(segment)
    }

    func appendToLastSegment(_ text: String) {
        if var last = segments.popLast() {
            last.text += " " + text
            segments.append(last)
        } else {
            segments.append(TranscriptSegment(speaker: .me, text: text, duration: 0))
        }
    }

    var formattedOutput: String {
        var output = "# \(meetingName)\n\n"
        output += "**Date:** \(startDate.formatted(date: .abbreviated, time: .shortened))\n\n"
        output += "---\n\n"

        for segment in segments {
            output += "[\(segment.formattedTimestamp)] **\(segment.speaker.displayName):** \(segment.text)\n\n"
        }

        if !notes.isEmpty {
            output += "---\n\n"
            output += "## Notes\n\n\(notes)\n"
        }

        if let summary = summary {
            output += "\n---\n\n"
            output += "## AI Summary\n\n\(summary)\n"
        }

        return output
    }
}
