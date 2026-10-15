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
    var speaker: SpeakerLabel
    var text: String
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
    var startDate: Date
    @Published var segments: [TranscriptSegment] = []
    @Published var notes: String = ""
    @Published var summary: String?
    @Published var isComplete: Bool = false

    private enum CodingKeys: String, CodingKey {
        case sessionID, meetingName, startDate, segments, notes, summary, isComplete
    }

    init(meetingName: String) {
        self.sessionID = UUID()
        self.meetingName = meetingName
        self.startDate = Date()
    }

    init(meetingName: String, startDate: Date) {
        self.sessionID = UUID()
        self.meetingName = meetingName
        self.startDate = startDate
    }

    // Custom Codable implementation to handle @Published properties
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        meetingName = try container.decode(String.self, forKey: .meetingName)
        startDate = try container.decode(Date.self, forKey: .startDate)
        segments = try container.decode([TranscriptSegment].self, forKey: .segments)
        notes = try container.decode(String.self, forKey: .notes)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        isComplete = try container.decode(Bool.self, forKey: .isComplete)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(meetingName, forKey: .meetingName)
        try container.encode(startDate, forKey: .startDate)
        try container.encode(segments, forKey: .segments)
        try container.encode(notes, forKey: .notes)
        try container.encode(summary, forKey: .summary)
        try container.encode(isComplete, forKey: .isComplete)
    }

    func addSegment(_ segment: TranscriptSegment) {
        segments.append(segment)
    }

    func appendToLastSegment(_ text: String) {
        if let last = segments.popLast() {
            let updatedSegment = TranscriptSegment(
                id: last.id,
                timestamp: last.timestamp,
                formattedTimestamp: last.formattedTimestamp,
                speaker: last.speaker,
                text: last.text + " " + text,
                duration: last.duration
            )
            segments.append(updatedSegment)
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
