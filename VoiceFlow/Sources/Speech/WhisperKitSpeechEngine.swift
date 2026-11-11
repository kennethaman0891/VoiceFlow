import Foundation
import WhisperKit

/// On-device WhisperKit engine. Models download once into Application Support
/// and stay there. whisper.cpp remains a fallback when this load fails.
final class WhisperKitSpeechEngine: SpeechTranscribing, @unchecked Sendable {

    private let pipe: WhisperKit

    private init(pipe: WhisperKit) {
        self.pipe = pipe
    }

    static func load(
        variant: String,
        progress: @escaping @Sendable (Double) -> Void,
        onWillLoad: @escaping @Sendable () -> Void = {}
    ) async throws -> WhisperKitSpeechEngine {
        let base = try modelsDirectory()
        let box = ProgressSink(progress)
        let folder = try await WhisperKit.download(
            variant: variant,
            downloadBase: base,
            progressCallback: { update in
                box.emit(update.fractionCompleted)
            }
        )
        onWillLoad()
        let pipe = try await WhisperKit(
            model: variant,
            downloadBase: base,
            modelFolder: folder.path,
            verbose: false,
            prewarm: false,
            load: true,
            download: false
        )
        return WhisperKitSpeechEngine(pipe: pipe)
    }

    func transcribe(samples: [Float], languageCode: String?) async throws -> String {
        guard !samples.isEmpty else { return "" }
        let detect = languageCode == nil || languageCode == SpeechModelCatalog.automaticLanguage
        let options = DecodingOptions(
            language: detect ? nil : languageCode,
            detectLanguage: detect,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            suppressBlank: true
        )
        let results: [TranscriptionResult] = try await pipe.transcribe(
            audioArray: samples,
            decodeOptions: options
        )
        return results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func modelsDirectory() throws -> URL {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceFlow", isDirectory: true)
            .appendingPathComponent("whisperkit", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Lets the download callback cross Swift 6 isolation without capturing the engine.
    private final class ProgressSink: @unchecked Sendable {
        let emit: @Sendable (Double) -> Void
        init(_ emit: @escaping @Sendable (Double) -> Void) {
            self.emit = emit
        }
    }
}
