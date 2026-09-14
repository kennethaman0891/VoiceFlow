import Foundation
import Combine

// MARK: - MeetingSession

/// Orchestrates a single meeting transcription session.
/// Records audio, transcribes in chunks, and saves results.
@MainActor
final class MeetingSession: ObservableObject {
    typealias CaptureStartOverride = @MainActor () async throws -> Void

    // MARK: - Published State

    @Published var isActive = false
    @Published private(set) var isStarting = false
    @Published private(set) var isDraining = false
    @Published var fileURL: URL?
    @Published var noAudioDetected = false
    @Published private(set) var isGeneratingSummary = false
    @Published var transcript: MeetingTranscript

    var onAutoStopRequested: ((MeetingSession) -> Void)?

    // MARK: - Private Properties

    private let saveDirectory: URL
    private let transcriber: SpeechTranscriber
    private let ocrService: FrontmostWindowOCRService?
    private let captureStartOverride: CaptureStartOverride?

    private var autoSaveTimer: Timer?
    private var silenceCheckTimer: Timer?
    private var meetingEndCheckTimer: Timer?
    private var hasReceivedAudio = false
    private var hasAutoUpdatedTitle = false
    private var skipCalendarAutoMatch = false
    private let originalName: String
    private var inactiveMeetingPollCount = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopRequested = false

    // MARK: - Init

    init(
        meetingName: String,
        transcriber: SpeechTranscriber,
        saveDirectory: URL,
        ocrService: FrontmostWindowOCRService? = nil,
        captureStartOverride: CaptureStartOverride? = nil
    ) {
        self.transcript = MeetingTranscript(meetingName: meetingName)
        self.transcriber = transcriber
        self.saveDirectory = saveDirectory
        self.originalName = meetingName
        self.ocrService = ocrService
        self.captureStartOverride = captureStartOverride
    }

    // MARK: - Public API

    /// Start the meeting recording session.
    func start() async throws {
        guard !isActive, !isDraining, !isStarting, !stopRequested else { return }

        isStarting = true
        defer {
            isStarting = false
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        // Start auto-save timer
        autoSaveTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.autoSave()
        }

        // Start silence detection
        silenceCheckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.checkSilence()
        }

        isActive = true
        hasReceivedAudio = false

        if let override = captureStartOverride {
            try await override()
        }
    }

    /// Stop the meeting recording session.
    func stop() async {
        guard isActive || isDraining else { return }

        stopRequested = true
        isDraining = true

        autoSaveTimer?.invalidate()
        autoSaveTimer = nil
        silenceCheckTimer?.invalidate()
        silenceCheckTimer = nil

        // Wait for pending transcription to complete
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        // Save final version
        await saveTranscript()

        // Generate summary
        await generateSummaryIfNeeded()

        isActive = false
        isDraining = false
        stopRequested = false
    }

    /// Add user notes to the meeting.
    func addNotes(_ notes: String) {
        transcript.notes = notes
        autoSave()
    }

    /// Generate AI summary for the meeting.
    func generateSummary() async {
        isGeneratingSummary = true
        defer { isGeneratingSummary = false }

        let summary = await MeetingSummaryGenerator.shared.generateSummary(for: transcript)
        transcript.summary = summary
        await saveTranscript()
    }

    // MARK: - Private

    private func autoSave() {
        Task { @MainActor in
            await saveTranscript()
        }
    }

    private func saveTranscript() async {
        do {
            let writer = MeetingMarkdownWriter.shared
            let url = try writer.save(transcript)
            fileURL = url
        } catch {
            print("[MeetingSession] Failed to save transcript: \(error)")
        }
    }

    private func generateSummaryIfNeeded() async {
        guard transcript.segments.count > 5 else { return } // Only summarize longer meetings
        await generateSummary()
    }

    private func checkSilence() {
        // In a real implementation, this would check audio levels
        // For now, just track if we've received any audio
        hasReceivedAudio = true
    }

    private func detectMeetingAppName() -> String? {
        // Check frontmost app for meeting indicators
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let name = app.localizedName ?? ""

        let meetingApps = ["zoom", "google meet", "teams", "webex", "slack"]
        for meetingApp in meetingApps {
            if name.lowercased().contains(meetingApp) {
                return name
            }
        }
        return nil
    }
}

// MARK: - SpeechTranscriber

/// Protocol for speech transcription services.
protocol SpeechTranscriber: AnyObject {
    func transcribe(samples: [Float]) async throws -> String
}

// MARK: - FrontmostWindowOCRService

/// Service for extracting text from screen (for meeting context).
class FrontmostWindowOCRService {
    func captureCurrentWindow() async -> String? {
        // Placeholder - in production, use Apple Vision framework for OCR
        return nil
    }
}
