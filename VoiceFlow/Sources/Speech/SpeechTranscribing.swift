import Foundation

/// One dictation engine. Implementations take 16 kHz mono Float32 samples and
/// return plain text. The coordinator does not care which backend ran.
protocol SpeechTranscribing: Sendable {
    func transcribe(samples: [Float], languageCode: String?) async throws -> String
}
