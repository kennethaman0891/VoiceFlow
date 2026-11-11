import Foundation
import Accelerate

// MARK: - VadEvent

public enum VadEvent: Sendable {
    case speechStarted
    case silenceCountdown(remainingSeconds: Double, progress: Double)
    case silenceTimeout(trailingSilenceSeconds: Double)
}

// MARK: - VadConfig

public struct VadConfig: Sendable {
    public var sampleRate: Double
    public var speechThreshold: Float
    public var silenceTimeoutSeconds: Double
    public var noiseFloorSmoothing: Float

    public init(
        sampleRate: Double = 16_000,
        speechThreshold: Float = 0.025,
        silenceTimeoutSeconds: Double = 2.0,
        noiseFloorSmoothing: Float = 0.05
    ) {
        self.sampleRate = sampleRate
        self.speechThreshold = speechThreshold
        self.silenceTimeoutSeconds = silenceTimeoutSeconds
        self.noiseFloorSmoothing = noiseFloorSmoothing
    }
}

// MARK: - VoiceActivityDetector

public final class VoiceActivityDetector: @unchecked Sendable {
    public var config: VadConfig
    private var noiseFloor: Float = 0.005
    private var hasSpoken: Bool = false
    private var silenceDuration: Double = 0.0
    private var lastFrameTime: Date?

    public init(config: VadConfig = VadConfig()) {
        self.config = config
    }

    public func reset() {
        noiseFloor = 0.005
        hasSpoken = false
        silenceDuration = 0.0
        lastFrameTime = nil
    }

    public func setSilenceTimeout(_ seconds: Double) {
        config.silenceTimeoutSeconds = max(0.5, seconds)
    }

    /// Process a frame of 16 kHz Float32 samples and returns any triggered VAD event.
    public func processFrame(_ samples: [Float]) -> VadEvent? {
        guard !samples.isEmpty else { return nil }

        // Compute RMS using Accelerate vDSP
        var rms: Float = 0.0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))

        let now = Date()
        let dt = lastFrameTime.map { now.timeIntervalSince($0) } ?? (Double(samples.count) / config.sampleRate)
        lastFrameTime = now

        let activeThreshold = max(config.speechThreshold, noiseFloor * 2.2)

        if rms > activeThreshold {
            // Speech detected
            silenceDuration = 0.0
            if !hasSpoken {
                hasSpoken = true
                return .speechStarted
            }
            return nil
        } else {
            // Update adaptive background noise floor
            noiseFloor = noiseFloor * (1.0 - config.noiseFloorSmoothing) + rms * config.noiseFloorSmoothing

            // Only track silence auto-stop after user has actually begun speaking
            guard hasSpoken else { return nil }

            silenceDuration += dt

            if silenceDuration >= config.silenceTimeoutSeconds {
                // Truncate 80% of silence timeout window to eliminate trailing dead air
                let trailingSilence = config.silenceTimeoutSeconds * 0.8
                return .silenceTimeout(trailingSilenceSeconds: trailingSilence)
            } else if silenceDuration >= 0.3 {
                let remaining = max(0, config.silenceTimeoutSeconds - silenceDuration)
                let progress = min(1.0, silenceDuration / config.silenceTimeoutSeconds)
                return .silenceCountdown(remainingSeconds: remaining, progress: progress)
            }

            return nil
        }
    }

    /// Trims trailing silence from sample buffer before transcription.
    public static func trimTrailingSilence(samples: [Float], sampleRate: Double = 16_000, trailingSilenceSeconds: Double = 1.6) -> [Float] {
        let samplesToTrim = Int(trailingSilenceSeconds * sampleRate)
        if samples.count > samplesToTrim + Int(sampleRate * 0.5) {
            return Array(samples.dropLast(samplesToTrim))
        }
        return samples
    }
}
