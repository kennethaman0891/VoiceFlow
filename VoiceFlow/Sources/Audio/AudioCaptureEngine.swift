import AVFoundation
import Foundation
import os

// MARK: - AudioCaptureEngine
//
// Captures microphone audio with AVAudioEngine and converts every input buffer
// to 16 kHz mono Float32 — the exact sample format whisper.cpp expects.
// Also integrates the VoiceActivityDetector for acoustic silence detection.

final class AudioCaptureEngine: @unchecked Sendable {

    // MARK: Errors

    enum CaptureError: LocalizedError {
        case microphoneDenied
        case noInputHardware
        case engineFailure(String)

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                return "Microphone access was not granted."
            case .noInputHardware:
                return "No microphone input available."
            case .engineFailure(let message):
                return "Audio capture failure: \(message)"
            }
        }
    }

    // MARK: Constants

    static let targetSampleRate: Double = 16_000
    /// Audio kept before the key goes down, so the first syllable is not clipped.
    static let preRollSeconds: Double = 0.4

    // MARK: State

    private let engine = AVAudioEngine()
    private let stateQueue = DispatchQueue(label: "com.kennethaman.VoiceFlow.audio-capture")
    private let captureFlag = OSAllocatedUnfairLock(initialState: false)

    private var convertedSamples: [Float] = []
    private var ring = AudioRingBuffer(capacity: Int(targetSampleRate * preRollSeconds))
    private var running = false
    private var converter: AVAudioConverter?
    private var onLevel: (@Sendable (Float) -> Void)?
    private var onVad: (@Sendable (VadEvent) -> Void)?
    public let vadDetector = VoiceActivityDetector()

    var isRunning: Bool {
        stateQueue.sync { running }
    }

    var isCapturingUtterance: Bool {
        captureFlag.withLock { $0 }
    }

    // MARK: Lifecycle

    /// Opens the microphone and keeps a short ring of recent audio.
    /// A later `start` copies that ring in as pre-roll. The tap stays installed
    /// across takes so the next hold still has the leading audio.
    func activateStandby(
        onLevel levelHandler: @escaping @Sendable (Float) -> Void,
        onVadEvent vadHandler: (@Sendable (VadEvent) -> Void)? = nil,
        silenceTimeoutSeconds: Double = 2.0
    ) throws {
        onLevel = levelHandler
        onVad = vadHandler
        vadDetector.setSilenceTimeout(silenceTimeoutSeconds)
        if isRunning { return }
        try installTapAndStart()
    }

    func start(
        onLevel levelHandler: @escaping @Sendable (Float) -> Void,
        onVadEvent vadHandler: (@Sendable (VadEvent) -> Void)? = nil,
        silenceTimeoutSeconds: Double = 2.0
    ) throws {
        try activateStandby(
            onLevel: levelHandler,
            onVadEvent: vadHandler,
            silenceTimeoutSeconds: silenceTimeoutSeconds
        )
        beginUtterance()
    }

    func beginUtterance() {
        vadDetector.reset()
        // Set the flag before snapshotting. A buffer that arrives in between is
        // queued on `stateQueue` and either lands in the ring (included by the
        // snapshot) or is appended after the snapshot overwrites the utterance.
        captureFlag.withLock { $0 = true }
        stateQueue.sync {
            convertedSamples = ring.snapshot()
        }
    }

    /// Ends the current take and leaves the microphone open for the next pre-roll.
    @discardableResult
    func stopAndReturnSamples(truncateSilenceSeconds: Double = 0.0) -> [Float] {
        captureFlag.withLock { $0 = false }
        return stateQueue.sync {
            defer { convertedSamples.removeAll(keepingCapacity: true) }
            if truncateSilenceSeconds > 0 {
                return VoiceActivityDetector.trimTrailingSilence(
                    samples: convertedSamples,
                    sampleRate: Self.targetSampleRate,
                    trailingSilenceSeconds: truncateSilenceSeconds
                )
            }
            return convertedSamples
        }
    }

    func shutdown() {
        captureFlag.withLock { $0 = false }
        let wasRunning = isRunning
        if wasRunning {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning {
                engine.stop()
            }
        }
        converter = nil
        stateQueue.sync {
            running = false
            convertedSamples.removeAll(keepingCapacity: false)
            ring.reset()
        }
    }

    private func installTapAndStart() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw CaptureError.microphoneDenied
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.noInputHardware
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false),
            let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.engineFailure("could not build \(Self.targetSampleRate) Hz mono Float32 converter")
        }

        stateQueue.sync {
            convertedSamples.removeAll(keepingCapacity: true)
            running = true
        }
        self.converter = converter

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.appendConverted(buffer: buffer, using: converter)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            self.converter = nil
            stateQueue.sync { running = false }
            throw CaptureError.engineFailure("AVAudioEngine failed to start: \(error.localizedDescription)")
        }
    }

    // MARK: Conversion

    private func appendConverted(
        buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter
    ) {
        guard buffer.frameLength > 0 else { return }

        let ratio = converter.outputFormat.sampleRate / max(buffer.format.sampleRate, 1)
        let capacity = max(AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024, 1024)
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return
        }

        var fedBuffer = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if fedBuffer {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fedBuffer = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, conversionError == nil, output.frameLength > 0,
              let channelData = output.floatChannelData?[0] else {
            return
        }

        let chunk = Array(UnsafeBufferPointer(start: channelData, count: Int(output.frameLength)))
        let capturing = captureFlag.withLock { $0 }
        stateQueue.async {
            self.ring.write(chunk)
            if capturing {
                self.convertedSamples.append(contentsOf: chunk)
            }
        }

        guard capturing else { return }

        if let onLevel {
            onLevel(min(Self.rmsLevel(of: buffer) * 4, 1))
        }
        if let onVad, let event = vadDetector.processFrame(chunk) {
            onVad(event)
        }
    }

    // MARK: Level metering

    private static func rmsLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sumSquares: Float = 0
        for i in 0..<count {
            let sample = data[i]
            sumSquares += sample * sample
        }
        return sqrt(sumSquares / Float(count))
    }
}
