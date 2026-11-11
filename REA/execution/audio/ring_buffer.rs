//! High-performance, lock-free or mutex-backed circular ring buffer for pre-speech capture.
//! Stores the trailing 500ms of 16kHz audio to prevent dropping leading consonants when
//! the user begins speaking concurrently with the hotkey press.

use std::sync::{Arc, Mutex};

/// A fixed-capacity circular buffer storing normalized 16kHz f32 audio samples.
#[derive(Debug, Clone)]
pub struct AudioRingBuffer {
    buffer: Vec<f32>,
    capacity: usize,
    write_pos: usize,
    count: usize,
}

impl AudioRingBuffer {
    /// Creates a ring buffer sized for the given duration in milliseconds at 16,000 Hz.
    /// E.g., for 500ms at 16kHz = 8,000 samples (~32 KB).
    pub fn with_duration_ms(duration_ms: u32) -> Self {
        let capacity = ((16_000 * duration_ms as usize) + 999) / 1000;
        Self {
            buffer: vec![0.0; capacity],
            capacity,
            write_pos: 0,
            count: 0,
        }
    }

    /// Push a slice of new incoming audio samples into the ring buffer.
    pub fn push_slice(&mut self, samples: &[f32]) {
        for &sample in samples {
            self.buffer[self.write_pos] = sample;
            self.write_pos = (self.write_pos + 1) % self.capacity;
            if self.count < self.capacity {
                self.count += 1;
            }
        }
    }

    /// Drain/extract the contiguous pre-roll samples in chronological order without clearing.
    pub fn snapshot(&self) -> Vec<f32> {
        let mut result = Vec::with_capacity(self.count);
        if self.count < self.capacity {
            result.extend_from_slice(&self.buffer[..self.count]);
        } else {
            // Buffer has wrapped around: older samples start at write_pos
            result.extend_from_slice(&self.buffer[self.write_pos..]);
            result.extend_from_slice(&self.buffer[..self.write_pos]);
        }
        result
    }

    /// Clears the ring buffer.
    pub fn clear(&mut self) {
        self.write_pos = 0;
        self.count = 0;
    }

    /// Total number of stored samples.
    pub fn len(&self) -> usize {
        self.count
    }

    pub fn is_empty(&self) -> bool {
        self.count == 0
    }
}

/// Thread-safe wrapper for concurrent audio capture threads.
#[derive(Clone)]
pub struct SharedAudioRingBuffer {
    inner: Arc<Mutex<AudioRingBuffer>>,
}

impl SharedAudioRingBuffer {
    pub fn new(duration_ms: u32) -> Self {
        Self {
            inner: Arc::new(Mutex::new(AudioRingBuffer::with_duration_ms(duration_ms))),
        }
    }

    pub fn push_slice(&self, samples: &[f32]) {
        if let Ok(mut buf) = self.inner.lock() {
            buf.push_slice(samples);
        }
    }

    pub fn snapshot(&self) -> Vec<f32> {
        self.inner.lock().map(|b| b.snapshot()).unwrap_or_default()
    }

    pub fn clear(&self) {
        if let Ok(mut buf) = self.inner.lock() {
            buf.clear();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ring_buffer_chronological_ordering() {
        let mut rb = AudioRingBuffer::with_duration_ms(1); // 16 samples
        let samples: Vec<f32> = (0..20).map(|x| x as f32).collect();
        rb.push_slice(&samples);

        assert_eq!(rb.len(), 16);
        let snap = rb.snapshot();
        assert_eq!(snap.len(), 16);
        // The last 16 of 20 should be 4..20
        let expected: Vec<f32> = (4..20).map(|x| x as f32).collect();
        assert_eq!(snap, expected);
    }
}
