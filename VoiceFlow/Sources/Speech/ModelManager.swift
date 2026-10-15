import Foundation
import CryptoKit

// MARK: - ModelManagerError

enum ModelManagerError: LocalizedError {
    case invalidModelName(String)
    case incompleteFile(path: String, size: Int64)
    case downloadFailed(String)
    case checksumMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .invalidModelName(let name):
            return "Invalid model name: \(name)"
        case .incompleteFile(let path, let size):
            return "Downloaded model at \(path) is too small (\(size) bytes); download incomplete."
        case .downloadFailed(let detail):
            return "Model download failed: \(detail)"
        case .checksumMismatch(let expected, let actual):
            return "Model checksum verification failed. Expected: \(expected), Got: \(actual)"
        }
    }
}

// MARK: - ModelCatalog

/// Known model checksums for integrity verification.
/// Source: ggerganov/whisper.cpp releases on Hugging Face.
private enum ModelCatalog {
    static let knownModels: [String: ModelInfo] = [
        "ggml-tiny": ModelInfo(
            filename: "ggml-tiny.bin",
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin",
            sizeMB: 75,
            sha256: "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21"
        ),
        "ggml-tiny.en": ModelInfo(
            filename: "ggml-tiny.en.bin",
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin",
            sizeMB: 75,
            sha256: "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f"
        ),
        "ggml-base": ModelInfo(
            filename: "ggml-base.bin",
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin",
            sizeMB: 148,
            sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"
        ),
        "ggml-base.en": ModelInfo(
            filename: "ggml-base.en.bin",
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin",
            sizeMB: 148,
            sha256: "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"
        ),
        "ggml-small": ModelInfo(
            filename: "ggml-small.bin",
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin",
            sizeMB: 488,
            sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"
        ),
        "ggml-small.en": ModelInfo(
            filename: "ggml-small.en.bin",
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin",
            sizeMB: 488,
            sha256: "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d"
        ),
        "ggml-medium": ModelInfo(
            filename: "ggml-medium.bin",
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin",
            sizeMB: 1500,
            sha256: "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208"
        ),
        "ggml-medium.en": ModelInfo(
            filename: "ggml-medium.en.bin",
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.en.bin",
            sizeMB: 1500,
            sha256: "cc37e93478338ec7700281a7ac30a10128929eb8f427dda2e865faa8f6da4356"
        ),
        "ggml-large-v3": ModelInfo(
            filename: "ggml-large-v3.bin",
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin",
            sizeMB: 3000,
            sha256: "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2"
        ),
    ]

    struct ModelInfo {
        let filename: String
        let url: String
        let sizeMB: Int
        let sha256: String
    }

    static func info(for name: String) -> ModelInfo? {
        return knownModels[name]
    }

    static func allNames() -> [String] {
        return Array(knownModels.keys).sorted()
    }
}

// MARK: - ModelManager
//
// Downloads and manages ggml Whisper model files under
// ~/Library/Application Support/VoiceFlow/models.
//
// Downloads use a URLSessionDownloadTask delegate so we can report fractional
// progress (URLSession's async `download(from:)` cannot). Completion is bridged
// to async/await via a checked continuation that is resumed exactly once.
// Integrity is verified via SHA-256 checksums.

final class ModelManager: NSObject, @unchecked Sendable {

    // MARK: Catalog

    /// Canonical location of whisper.cpp ggml models (ggerganov mirror).
    static let modelsBaseURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/")!

    /// Generic lower bound for "this file is a real model". Real models are far
    /// larger (tiny.en ≈ 75 MB … small.en ≈ 488 MB); anything below this is a
    /// truncated or bogus file.
    static let minimumValidModelBytes: Int64 = 10_000_000

    // MARK: State

    private let fileManager = FileManager.default

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private let lock = NSLock()
    private var activeDownloads: [Int: DownloadRecord] = [:]

    /// Bridges main-actor state updates across the nonisolated download path:
    /// only this `@unchecked Sendable` box crosses concurrency boundaries; the
    /// AppState reference is unwrapped inside the main-actor task.
    private final class WeakMainActorRef<Object: AnyObject>: @unchecked Sendable {
        private weak var object: Object?
        init(_ object: Object) {
            self.object = object
        }

        /// Read from the main actor.
        var value: Object? { object }
    }

    /// One in-flight download. `takeContinuation()` guarantees single resume.
    private final class DownloadRecord: @unchecked Sendable {
        let destination: URL
        let expectedSHA256: String?
        // Invoked from the session delegate queue; the caller hops to its own
        // actor internally (see ensureModel).
        let progressHandler: @Sendable (Double) -> Void

        private let stateLock = NSLock()
        private var continuation: CheckedContinuation<URL, Error>?
        private var resumed = false

        init(destination: URL,
             expectedSHA256: String?,
             progressHandler: @escaping @Sendable (Double) -> Void,
             continuation: CheckedContinuation<URL, Error>) {
            self.destination = destination
            self.expectedSHA256 = expectedSHA256
            self.progressHandler = progressHandler
            self.continuation = continuation
        }

        func takeContinuation() -> CheckedContinuation<URL, Error>? {
            stateLock.lock()
            defer { stateLock.unlock() }
            guard !resumed else { return nil }
            resumed = true
            defer { continuation = nil }
            return continuation
        }
    }

    // MARK: Paths

    /// Models directory, created on demand:
    /// ~/Library/Application Support/VoiceFlow/models
    var modelsDirectory: URL {
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceFlow", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func localModelURL(for name: String) -> URL {
        modelsDirectory.appendingPathComponent("\(name).bin")
    }

    // MARK: Public API

    /// Returns all known model names from the catalog.
    static func availableModels() -> [String] {
        return ModelCatalog.allNames()
    }

    /// Returns model info from catalog if available.
    static func modelInfo(for name: String) -> (url: URL, sha256: String, sizeMB: Int)? {
        guard let info = ModelCatalog.info(for: name) else { return nil }
        return (URL(string: info.url)!, info.sha256, info.sizeMB)
    }

    // MARK: Status

    /// Check if model exists locally and passes size check.
    func isDownloaded(_ name: String) -> Bool {
        let url = localModelURL(for: name)
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int64 else { return false }
        return size >= Self.minimumValidModelBytes
    }

    /// Check if model exists locally and passes SHA-256 verification.
    func isVerified(_ name: String) -> Bool {
        guard let catalogInfo = ModelCatalog.info(for: name) else {
            // Unknown model - fall back to size check
            return isDownloaded(name)
        }
        let url = localModelURL(for: name)
        guard fileManager.fileExists(atPath: url.path) else { return false }
        do {
            let actualHash = try computeSHA256(url)
            return actualHash.lowercased() == catalogInfo.sha256.lowercased()
        } catch {
            return false
        }
    }

    // MARK: Checksums

    /// Compute SHA-256 hash of a file using CryptoKit.
    func computeSHA256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Verify file at URL against expected SHA-256 hash.
    func verifySHA256(_ url: URL, expected: String) throws -> Bool {
        let actual = try computeSHA256(url)
        return actual.lowercased() == expected.lowercased()
    }

    // MARK: Download

    /// Downloads `name` (e.g. "ggml-base.en") unless a valid copy already
    /// exists locally. Reports progress 0...1 through `progress`. The file is
    /// moved into place atomically on success; partial files are deleted.
    /// Verifies SHA-256 checksum after download.
    func downloadIfNeeded(_ name: String,
                          progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        // Check if already verified
        if isVerified(name) {
            return localModelURL(for: name)
        }

        // Check catalog for expected checksum
        let catalogInfo = ModelCatalog.info(for: name)
        let expectedSHA256 = catalogInfo?.sha256

        // Keep the remote filename construction safe.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
        guard !name.isEmpty, name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw ModelManagerError.invalidModelName(name)
        }

        let remoteURL: URL
        if let catalogInfo = catalogInfo {
            remoteURL = URL(string: catalogInfo.url)!
        } else {
            // Fallback for unknown models
            remoteURL = URL(string: "\(name).bin", relativeTo: Self.modelsBaseURL)!
        }
        let destination = localModelURL(for: name)

        // Clear any stale/partial artifact before starting fresh.
        try? fileManager.removeItem(at: destination)

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            let task = session.downloadTask(with: remoteURL)
            activeDownloads[task.taskIdentifier] = DownloadRecord(
                destination: destination,
                expectedSHA256: expectedSHA256,
                progressHandler: progress,
                continuation: continuation)
            lock.unlock()
            task.resume()
        }
    }

    // MARK: App-state orchestration

    /// Ensures the model exists, driving `appState.modelStatus` through
    /// downloading/ready/failed. Returns the local URL when ready, else nil.
    ///
    /// MainActor-isolated because it mutates observable UI state between awaits.
    @MainActor
    func ensureModel(_ name: String, appState: AppState) async -> URL? {
        if isVerified(name) {
            appState.modelStatus = .ready
            return localModelURL(for: name)
        }

        appState.modelStatus = .downloading(0)

        let stateRef = WeakMainActorRef(appState)
        do {
            let url = try await downloadIfNeeded(name) { fraction in
                let ref = stateRef
                Task { @MainActor in
                    ref.value?.modelStatus = .downloading(min(max(fraction, 0), 1))
                }
            }
            appState.modelStatus = .ready
            return url
        } catch {
            appState.modelStatus = .failed(error.localizedDescription)
            return nil
        }
    }

    // MARK: Record lookup

    private func record(for task: URLSessionTask) -> DownloadRecord? {
        lock.lock()
        defer { lock.unlock() }
        return activeDownloads[task.taskIdentifier]
    }

    private func finishRecord(_ record: DownloadRecord, task: URLSessionTask) {
        lock.lock()
        activeDownloads[task.taskIdentifier] = nil
        lock.unlock()
    }
}

// MARK: - URLSessionDownloadDelegate

extension ModelManager: URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0,
              let record = record(for: downloadTask) else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        record.progressHandler(min(max(fraction, 0), 1))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let record = record(for: downloadTask) else { return }

        do {
            try fileManager.createDirectory(at: record.destination.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: record.destination.path) {
                try fileManager.removeItem(at: record.destination)
            }
            // Atomic move of URLSession's completed temp file into place.
            try fileManager.moveItem(at: location, to: record.destination)

            let attributes = try? fileManager.attributesOfItem(atPath: record.destination.path)
            let size = (attributes?[.size] as? Int64) ?? 0
            guard size >= Self.minimumValidModelBytes else {
                throw ModelManagerError.incompleteFile(path: record.destination.path, size: size)
            }

            // Verify SHA-256 checksum if expected
            if let expectedSHA256 = record.expectedSHA256 {
                let actualHash = try computeSHA256(record.destination)
                guard actualHash.lowercased() == expectedSHA256.lowercased() else {
                    throw ModelManagerError.checksumMismatch(expected: expectedSHA256, actual: actualHash)
                }
            }

            finishRecord(record, task: downloadTask)
            record.takeContinuation()?.resume(returning: record.destination)
        } catch {
            try? fileManager.removeItem(at: record.destination)
            finishRecord(record, task: downloadTask)
            record.takeContinuation()?.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // Success also passes through here with error == nil AFTER
        // didFinishDownloadingTo handled the move; only handle real failures.
        guard let error,
              let downloadTask = task as? URLSessionDownloadTask,
              let record = record(for: downloadTask) else { return }

        try? fileManager.removeItem(at: record.destination)
        finishRecord(record, task: downloadTask)
        record.takeContinuation()?
            .resume(throwing: ModelManagerError.downloadFailed(error.localizedDescription))
    }
}
