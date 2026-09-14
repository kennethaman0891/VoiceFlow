import Foundation
import Combine

// MARK: - MeetingManager

/// Manages active meeting sessions and provides UI state.
@MainActor
final class MeetingManager: ObservableObject {
    static let shared = MeetingManager()

    @Published var activeSession: MeetingSession?
    @Published var isRecording = false
    @Published var currentMeetingName: String = ""

    private let history = MeetingHistory.shared

    private init() {}

    // MARK: - Public API

    /// Start a new meeting with auto-detected name.
    func startMeeting() async {
        guard activeSession == nil else { return }

        let detector = MeetingDetector.shared
        let meetingName = detector.generateMeetingName()
        currentMeetingName = meetingName

        await startMeeting(named: meetingName)
    }

    /// Start a new meeting with a specific name.
    func startMeeting(named name: String) async {
        guard activeSession == nil else { return }

        let session = MeetingSession(
            meetingName: name,
            transcriber: DummyTranscriber(),
            saveDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("VoiceFlow")
                .appendingPathComponent("meetings")
        )

        activeSession = session
        isRecording = true

        do {
            try await session.start()
        } catch {
            print("[MeetingManager] Failed to start meeting: \(error)")
            activeSession = nil
            isRecording = false
        }
    }

    /// Stop the current meeting.
    func stopMeeting() async {
        guard let session = activeSession else { return }

        isRecording = false
        await session.stop()

        // Refresh history
        await history.refresh()

        activeSession = nil
        currentMeetingName = ""
    }

    /// Get list of past meetings.
    var pastMeetings: [SavedMeeting] {
        history.meetings
    }
}

// MARK: - DummyTranscriber

/// Placeholder transcriber for meeting demo.
class DummyTranscriber: SpeechTranscriber {
    func transcribe(samples: [Float]) async throws -> String {
        // In production, use real WhisperEngine
        return "This is a placeholder transcript."
    }
}
