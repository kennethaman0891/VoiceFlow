import Foundation

/// Fixed-capacity sample ring. `snapshot()` returns samples in time order,
/// oldest first. Used for the ~400 ms pre-roll ahead of a key press.
struct AudioRingBuffer {
    private var storage: [Float]
    private var next = 0
    private var filled = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
        storage = Array(repeating: 0, count: self.capacity)
    }

    var count: Int { filled }

    mutating func write(_ samples: [Float]) {
        for sample in samples {
            storage[next] = sample
            next = (next + 1) % capacity
            if filled < capacity {
                filled += 1
            }
        }
    }

    func snapshot() -> [Float] {
        guard filled > 0 else { return [] }
        if filled < capacity {
            return Array(storage[0..<filled])
        }
        return Array(storage[next..<capacity]) + Array(storage[0..<next])
    }

    mutating func reset() {
        next = 0
        filled = 0
    }
}
