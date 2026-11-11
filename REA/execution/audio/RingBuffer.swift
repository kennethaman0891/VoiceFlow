import Foundation

/// A fixed-capacity circular ring buffer storing trailing 16kHz Float audio samples.
/// Designed for low-latency pre-speech audio capture to ensure zero phoneme clipping.
public final class AudioRingBuffer: @unchecked Sendable {
    private var buffer: [Float]
    private let capacity: Int
    private var writeIndex: Int = 0
    private var count: Int = 0
    private let lock = NSLock()

    /// Initializes a ring buffer for the specified duration at 16,000 Hz.
    /// Default duration: 500ms = 8,000 samples.
    public init(durationMs: Int = 500, sampleRate: Double = 16000.0) {
        let cap = Int((sampleRate * Double(durationMs) / 1000.0).rounded(.up))
        self.capacity = max(cap, 1)
        self.buffer = [Float](repeating: 0.0, count: self.capacity)
    }

    /// Appends incoming audio samples to the ring buffer.
    public func append(_ samples: UnsafeBufferPointer<Float>) {
        lock.lock()
        defer { lock.unlock() }

        for sample in samples {
            buffer[writeIndex] = sample
            writeIndex = (writeIndex + 1) % capacity
            if count < capacity {
                count += 1
            }
        }
    }

    /// Appends incoming audio samples from a Swift array.
    public func append(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { append($0) }
    }

    /// Retrieves all buffered pre-roll samples in chronological order.
    public func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        guard count > 0 else { return [] }

        var result = [Float]()
        result.reserveCapacity(count)

        if count < capacity {
            result.append(contentsOf: buffer[0..<count])
        } else {
            // Wrapped buffer: oldest samples begin at writeIndex
            result.append(contentsOf: buffer[writeIndex..<capacity])
            result.append(contentsOf: buffer[0..<writeIndex])
        }

        return result
    }

    /// Clears the ring buffer.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        writeIndex = 0
        count = 0
    }

    /// Number of active samples stored.
    public var sampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
