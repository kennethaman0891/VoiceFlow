import AVFoundation
import Foundation

// MARK: - AudioCaptureEngine
//
// Captures microphone audio with AVAudioEngine and converts every input buffer
// to 16 kHz mono Float32 — the exact sample format whisper.cpp expects.
//
// Threading model:
// - `engine` and the tap are owned by this class; tap callbacks arrive serially
//   on AVFoundation's internal audio queue.
// - Accumulated samples are guarded by an internal serial queue (`stateQueue`).
// - `onLevel` is invoked from the audio queue; it is marked `@Sendable` so the
//   caller (DictationCoordinator) is forced to hop to the main actor itself.

final class AudioCaptureEngine: @unchecked Sendable {

    // MARK: Errors

    enum CaptureError: LocalizedError {
        /// Microphone permission denied (or not yet granted).
        case microphoneDenied
        /// No usable input hardware / empty hardware format.
        case noInputHardware
        /// Converter or engine failure with a descriptive message.
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

    /// Target sample rate for whisper.cpp (it resamples internally to 16 kHz mel).
    static let targetSampleRate: Double = 16_000

    // MARK: State

    private let engine = AVAudioEngine()

    /// Guards `convertedSamples`, `running`, and `tapActive`.
    private let stateQueue = DispatchQueue(label: "com.kennethaman.VoiceFlow.audio-capture")

    private var convertedSamples: [Float] = []
    private var running = false
    private var converter: AVAudioConverter?

    var isRunning: Bool {
        stateQueue.sync { running }
    }

    // MARK: Lifecycle

    /// Installs the input tap and starts the engine.
    ///
   /// Throws `CaptureError.microphoneDenied` unless microphone authorization
    /// is already `.authorized` (the coordinator requests permission first).
    func start(onLevel levelHandler: @escaping @Sendable (Float) -> Void) throws {
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

            // UI level metering: RMS scaled up for visibility on quiet mics.
            let rms = Self.rmsLevel(of: buffer)
            levelHandler(min(rms * 4, 1))

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

    /// Removes the tap, stops the engine, and returns all samples captured
    /// since `start(onLevel:)` (16 kHz mono Float32). Resets internal buffers.
    @discardableResult
    func stopAndReturnSamples() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning {
            engine.stop()
        }
        converter = nil
        return stateQueue.sync {
            running = false
            defer { convertedSamples.removeAll(keepingCapacity: false) }
            return convertedSamples
        }
    }

    // MARK: Conversion

    /// Converts one hardware-format buffer to 16 kHz mono Float32 and appends
    /// the result to the protected accumulator. Runs on the tap's audio queue;
    /// `converter` is only ever touched from that serial queue.
    private func appendConverted(buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) {
        guard buffer.frameLength > 0 else { return }

        // Capacity estimate for resampling + headroom for filter flush.
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
        stateQueue.async {
            self.convertedSamples.append(contentsOf: chunk)
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
