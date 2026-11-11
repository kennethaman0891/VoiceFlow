import Foundation

/// Decides whether a finished hold should be transcribed and whether the text
/// should be pasted. Hold length is wall-clock key time, so a pre-roll buffer
/// cannot turn a tap into a take.
enum DictationGate {
    /// 300 ms at 16 kHz. Shorter buffers are not speech.
    static let minimumSampleCount = 4_800

    static func shouldTranscribe(
        sampleCount: Int,
        holdDuration: TimeInterval,
        minimumDuration: TimeInterval
    ) -> Bool {
        holdDuration >= minimumDuration && sampleCount >= minimumSampleCount
    }

    static func shouldPaste(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
