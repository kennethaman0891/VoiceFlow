import Foundation

// MARK: - MeetingHistory

/// Manages the collection of saved meeting transcripts.
@MainActor
final class MeetingHistory: ObservableObject {
    static let shared = MeetingHistory()

    @Published var meetings: [SavedMeeting] = []
    @Published var isLoading = false

    private let writer = MeetingMarkdownWriter.shared

    private init() {
        refresh()
    }

    // MARK: - Public API

    /// Refresh the meeting list from disk.
    func refresh() {
        meetings = writer.listMeetings()
    }

    /// Get a meeting by URL.
    func getMeeting(at url: URL) async throws -> MeetingTranscript {
        isLoading = true
        defer { isLoading = false }
        return try await writer.load(from: url)
    }

    /// Delete a meeting.
    func delete(_ meeting: SavedMeeting) throws {
        try writer.delete(meeting.url)
        refresh()
    }

    /// Get recent meetings (last N).
    func recentMeetings(limit: Int = 10) -> [SavedMeeting] {
        return meetings.prefix(limit).map { $0 }
    }

    /// Search meetings by keyword.
    func search(_ query: String) -> [SavedMeeting] {
        guard !query.isEmpty else { return meetings }

        return meetings.filter { meeting in
            // Check filename
            if meeting.fileName.lowercased().contains(query.lowercased()) {
                return true
            }

            // Try to load and search content (expensive, so limit results)
            do {
                let transcript = try await writer.load(from: meeting.url)
                return transcript.formattedOutput.lowercased().contains(query.lowercased())
            } catch {
                return false
            }
        }
    }

    // MARK: - Statistics

    var totalMeetings: Int { meetings.count }

    var totalDuration: TimeInterval {
        meetings.reduce(0) { total, meeting in
            total + (meeting.modificationDate.distance(to: Date()))
        }
    }
}
