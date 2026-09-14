import Foundation

// NOTE: `import whisper` exposes the C API of the whisper.cpp system library
// (resolved by SwiftPM through pkg-config; see VoiceFlow.yml packages block).
import whisper

// MARK: - WhisperError

enum WhisperError: LocalizedError {
    case modelNotFound(String)
    case loadFailed(String)
    case transcribeFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let path):
            return "Whisper model file not found at \(path)"
        case .loadFailed(let detail):
            return "Failed to initialize whisper.cpp context: \(detail)"
        case .transcribeFailed(let code):
            return "whisper_full failed with error code \(code)"
        }
    }
}

// MARK: - WhisperEngine
//
// Thin wrapper over the whisper.cpp C API. One engine owns exactly one
// `whisper_context`, which is NOT thread-safe — all context access is
// therefore serialized on an internal serial queue.
//
// Model loading takes seconds (hundreds of MB), so prefer `create(modelPath:)`
// which performs initialization off the main actor.

final class WhisperEngine: @unchecked Sendable {

    /// Opaque `whisper_context *`. Freed in deinit via `whisper_free`.
    private let context: OpaquePointer

    /// Serializes all access to `context` (init-time loads and transcriptions).
    private let workQueue = DispatchQueue(label: "com.kennethaman.VoiceFlow.whisper", qos: .userInitiated)

    /// C-string holder with process lifetime for whisper_full_params fields
    /// (`const char *` must outlive the transcription call).
    private struct ConstantCString: @unchecked Sendable {
        let pointer: UnsafePointer<CChar>

        init(_ string: String) {
            pointer = UnsafePointer(strdup(string)!)
        }

        /// Intentionally never freed: the instance is a static constant and
        /// lives for the entire process.
    }

    private static let englishLanguageCode = ConstantCString("en")

    // MARK: GGML backend bootstrap
    //
    // The app dynamically links Homebrew's libwhisper (1.9.2) + libggml (0.21.0).
    // Under dynamic linking the ggml backend device registry (CPU/BLAS/Metal) is
    // never populated automatically, so `whisper_init_from_file_with_params` fails
    // immediately with `GGML_ASSERT(device) failed` in `ggml_backend_dev_init`.
    //
    // Calling ggml's `ggml_backend_load_all()` once before creating the context
    // populates that registry (verified with a C test: devices=3, backends=3).
    //
    // The function is a plain C helper exported by libggml.dylib but NOT exposed
    // through the `whisper` module: whisper.cpp's module.modulemap exposes only
    // `whisper.h`, which `#include`s ggml.h + ggml-cpu.h — neither declares
    // `ggml_backend_load_all` (that lives in ggml-backend.h, which is not pulled
    // in). We therefore resolve and invoke it at runtime via dlopen/dlsym against
    // the exact dylib the app links, which is robust under Swift 6 strict
    // concurrency and independent of how SwiftPM maps the module headers.

    /// Resolves and runs `ggml_backend_load_all()` exactly once, thread-safely.
    /// Cheap and idempotent; safe to call before every context creation.
    private final class GGMLBackendLoader: @unchecked Sendable {
        static let shared = GGMLBackendLoader()

        private let lock = NSLock()
        private var loaded = false

        func loadIfNeeded() {
            lock.lock()
            defer { lock.unlock() }
            // Mark before invoking so a concurrent caller can never double-run.
            guard !loaded else { return }
            loaded = true

            guard let handle = dlopen("/opt/homebrew/lib/libggml.dylib", RTLD_LAZY | RTLD_LOCAL),
                  let symbol = dlsym(handle, "ggml_backend_load_all") else {
                // If resolution fails, log and continue: whisper_init will surface
                // its own error if the backend registry is genuinely missing.
                NSLog("VoiceFlow: could not resolve ggml_backend_load_all; proceeding (ggml backends may be unregistered).")
                return
            }

            typealias LoadAllFn = @convention(c) () -> Void
            let loadAll = unsafeBitCast(symbol, to: LoadAllFn.self)
            loadAll()
        }
    }

    // MARK: Init

    /// Loads the ggml model at `modelPath` and creates the whisper context.
    ///
    /// Heavy (reads + parses the whole model); call from a background context —
    /// or use `create(modelPath:)` which hops automatically.
    init(modelPath: String) throws {
        // Populate the ggml backend registry before touching whisper, otherwise
        // the first context creation asserts with `GGML_ASSERT(device) failed`.
        GGMLBackendLoader.shared.loadIfNeeded()

        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw WhisperError.modelNotFound(modelPath)
        }

        var contextParams = whisper_context_default_params()
        guard let ctx = whisper_init_from_file_with_params(modelPath, contextParams) else {
            throw WhisperError.loadFailed("whisper_init_from_file_with_params returned NULL for \(modelPath)")
        }
        context = ctx
    }

    /// Convenience factory that performs model loading off the main thread.
    static func create(modelPath: String) async throws -> WhisperEngine {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try WhisperEngine(modelPath: modelPath))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    deinit {
        // `context` is a plain C pointer; free it explicitly. whisper_free is
        // a simple release call, safe to run wherever ARC drops us.
        whisper_free(context)
    }

    // MARK: Transcription

    /// Transcribes 16 kHz mono Float32 samples into English text.
    ///
    /// Hops to the internal serial queue, so calls from any isolation domain
    /// are safe; concurrent callers queue up behind each other.
    func transcribe(samples: [Float]) async throws -> String {
        guard !samples.isEmpty else { return "" }

        return try await withCheckedThrowingContinuation { continuation in
            workQueue.async { [context] in
                do {
                    continuation.resume(returning: try Self.runTranscription(context: context, samples: samples))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runTranscription(context: OpaquePointer, samples: [Float]) throws -> String {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)

        // Quiet operation: no stdout spam from inside whisper.cpp.
        params.print_realtime = false
        params.print_progress = false
        params.print_special = false
        params.print_timestamps = false

        // English-only dictation.
        params.language = Self.englishLanguageCode.pointer
        params.detect_language = false
        params.translate = false

        // Each recording is independent; don't condition on past output.
        params.no_context = true

        // Leave one core headroom for UI/audio work.
        params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 1)))

        // Suppress blank/non-speech token loops common on silence.
        params.suppress_blank = true
        params.suppress_nst = true

        // Fast greedy decoding is plenty for short dictation bursts.
        params.greedy.best_of = 1

        let result = samples.withUnsafeBufferPointer { buffer -> Int32 in
            whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
        }
        guard result == 0 else {
            throw WhisperError.transcribeFailed(result)
        }

        var parts: [String] = []
        let segmentCount = whisper_full_n_segments(context)
        if segmentCount > 0 {
            for index in 0..<segmentCount {
                if let cText = whisper_full_get_segment_text(context, Int32(index)) {
                    parts.append(String(cString: cText))
                }
            }
        }

        return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
