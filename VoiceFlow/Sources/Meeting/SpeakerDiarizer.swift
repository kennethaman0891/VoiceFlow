import Foundation
import Accelerate

// MARK: - SpeakerSegment

struct SpeakerSegment: Identifiable {
    let id: UUID
    let startTimestamp: Date
    let endTimestamp: Date
    let speakerId: String
    let text: String
    let confidence: Double

    var duration: TimeInterval {
        endTimestamp.timeIntervalSince(startTimestamp)
    }
}

// MARK: - SpeakerDiarizer

/// Uses audio embeddings to identify different speakers in recordings.
@MainActor
final class SpeakerDiarizer: ObservableObject {
    static let shared = SpeakerDiarizer()

    @Published var speakers: [SpeakerInfo] = []
    @Published var isProcessing = false

    private var speakerCount = 0
    private let maxSpeakers = 10

    private init() {}

    // MARK: - Public API

    /// Analyze audio samples and assign speaker labels.
    func diarize(samples: [Float], duration: TimeInterval) async -> [SpeakerSegment] {
        isProcessing = true
        defer { isProcessing = false }

        // Split audio into chunks for analysis
        let chunkSize = Int(16000 * 2.5) // 2.5 second chunks at 16kHz
        var segments: [SpeakerSegment] = []
        var currentSpeaker: String?

        for i in stride(from: 0, to: samples.count, by: chunkSize) {
            let end = min(i + chunkSize, samples.count)
            let chunk = Array(samples[i..<end])

            // Simplified speaker detection (in production, use x-vector or similar)
            let detectedSpeaker = detectSpeaker(from: chunk)

            if currentSpeaker == nil {
                currentSpeaker = detectedSpeaker
                speakerCount += 1
            }

            let segmentStart = Date().addingTimeInterval(-Double(samples.count - end) / 16000.0)
            let segmentEnd = Date()

            segments.append(SpeakerSegment(
                id: UUID(),
                startTimestamp: segmentStart,
                endTimestamp: segmentEnd,
                speakerId: currentSpeaker ?? "unknown",
                text: "", // Text populated from transcription
                confidence: 0.8
            ))
        }

        return segments
    }

    /// Merge diarization results with transcribed text.
    func mergeWithTranscript(_ segments: [SpeakerSegment], transcript: MeetingTranscript) {
        guard segments.count == transcript.segments.count else { return }

        for (i, diagSegment) in segments.enumerated() {
            if diagSegment.speakerId != "unknown" {
                transcript.segments[i].speaker = .remote(name: "Speaker \(diagSegment.speakerId)")
            }
        }
    }

    // MARK: - Private

    private func detectSpeaker(from chunk: [Float]) -> String {
        // Placeholder: In production, use Mel-frequency cepstral coefficients (MFCCs)
        // and clustering (e.g., KMeans) to identify unique speakers.
        // For now, we use a simple energy-based heuristic.
        let energy = calculateEnergy(from: chunk)

        // Simple heuristic: high energy = speaker 1, low energy = speaker 2
        if energy > 0.5 {
            return "1"
        } else {
            return "2"
        }
    }

    private func calculateEnergy(from samples: [Float]) -> Float {
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return sum / Float(samples.count)
    }
}

// MARK: - SpeakerInfo

struct SpeakerInfo: Identifiable, Equatable {
    let id: String
    let label: String
    let sampleCount: Int
    let averageEnergy: Float

    var color: Color {
        switch id {
        case "1": return .blue
        case "2": return .green
        case "3": return .orange
        case "4": return .purple
        default: return .gray
        }
    }
}
