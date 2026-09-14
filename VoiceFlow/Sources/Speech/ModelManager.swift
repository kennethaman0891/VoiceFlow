import Foundation

// MARK: - ModelManagerError

enum ModelManagerError: LocalizedError {
    case invalidModelName(String)
    case incompleteFile(path: String, size: Int64)
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidModelName(let name):
            return "Invalid model name: \(name)"
        case .incompleteFile(let path, let size):
            return "Downloaded model at \(path) is too small (\(size) bytes); download incomplete."
        case .downloadFailed(let detail):
            return "Model download failed: \(detail)"
        }
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
        // Invoked from the session delegate queue; the caller hops to its own
        // actor internally (see ensureModel).
        let progressHandler: @Sendable (Double) -> Void

        private let stateLock = NSLock()
        private var continuation: CheckedContinuation<URL, Error>?
        private var resumed = false

        init(destination: URL,
             progressHandler: @escaping @Sendable (Double) -> Void,
             continuation: CheckedContinuation<URL, Error>) {
            self.destination = destination
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

    // MARK: Status

    func isDownloaded(_ name: String) -> Bool {
        let url = localModelURL(for: name)
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int64 else { return false }
        return size >= Self.minimumValidModelBytes
    }

    // MARK: Download

    /// Downloads `name` (e.g. "ggml-base.en") unless a valid copy already
    /// exists locally. Reports progress 0...1 through `progress`. The file is
    /// moved into place atomically on success; partial files are deleted.
    func downloadIfNeeded(_ name: String,
                          progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if isDownloaded(name) {
            return localModelURL(for: name)
        }

        // Keep the remote filename construction safe.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
        guard !name.isEmpty, name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw ModelManagerError.invalidModelName(name)
        }

        let remoteURL = URL(string: "\(name).bin", relativeTo: Self.modelsBaseURL)!
        let destination = localModelURL(for: name)

        // Clear any stale/partial artifact before starting fresh.
        try? fileManager.removeItem(at: destination)

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            let task = session.downloadTask(with: remoteURL)
            activeDownloads[task.taskIdentifier] = DownloadRecord(
                destination: destination,
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
        if isDownloaded(name) {
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
