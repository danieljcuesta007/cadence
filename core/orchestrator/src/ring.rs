//! Audio ring buffer (§18 step 2): capture begins at key-down, before any model is warm, and
//! pre-roll capacity means words spoken in the first instant are never lost (AC-5). Overwrite
//! policy drops the OLDEST samples first — the freshest speech is always intact — and the
//! number of dropped samples is tracked so the "no lost words" invariant is observable.

/// Fixed-capacity ring buffer of PCM samples.
pub struct RingBuffer {
    buf: Vec<i16>,
    head: usize, // next write position
    len: usize,  // valid samples (≤ capacity)
    dropped: u64,
}

impl RingBuffer {
    /// `capacity` in samples. At 16 kHz mono, 16_000 * seconds.
    pub fn new(capacity: usize) -> Self {
        assert!(capacity > 0, "ring buffer capacity must be non-zero");
        Self {
            buf: vec![0; capacity],
            head: 0,
            len: 0,
            dropped: 0,
        }
    }

    pub fn capacity(&self) -> usize {
        self.buf.len()
    }

    pub fn len(&self) -> usize {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// Total samples overwritten before being drained (0 in normal operation).
    pub fn dropped(&self) -> u64 {
        self.dropped
    }

    /// Append samples, overwriting oldest on overflow.
    pub fn push(&mut self, samples: &[i16]) {
        let cap = self.buf.len();
        if samples.len() >= cap {
            // Only the trailing `cap` samples survive; everything else counts as dropped,
            // plus whatever unread data was already in the buffer.
            self.dropped += (samples.len() - cap) as u64 + self.len as u64;
            self.buf.copy_from_slice(&samples[samples.len() - cap..]);
            self.head = 0;
            self.len = cap;
            return;
        }
        let overflow = (self.len + samples.len()).saturating_sub(cap);
        self.dropped += overflow as u64;
        for &s in samples {
            self.buf[self.head] = s;
            self.head = (self.head + 1) % cap;
        }
        self.len = (self.len + samples.len()).min(cap);
    }

    /// Copy the buffered window in chronological order **without** consuming it. Used by the
    /// instant pass (§12.3), which re-reads the growing window while the user is still speaking;
    /// the refined pass still [`drain`](RingBuffer::drain)s at end-of-utterance.
    pub fn snapshot(&self) -> Vec<i16> {
        let cap = self.buf.len();
        let start = (self.head + cap - self.len) % cap;
        let mut out = Vec::with_capacity(self.len);
        for i in 0..self.len {
            out.push(self.buf[(start + i) % cap]);
        }
        out
    }

    /// Drain the buffered window in chronological order and reset.
    pub fn drain(&mut self) -> Vec<i16> {
        let out = self.snapshot();
        self.head = 0;
        self.len = 0;
        out
    }

    /// Discard buffered audio (cancel path, §7 F6).
    pub fn clear(&mut self) {
        self.head = 0;
        self.len = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preserves_order_within_capacity() {
        let mut r = RingBuffer::new(8);
        r.push(&[1, 2, 3]);
        r.push(&[4, 5]);
        assert_eq!(r.drain(), vec![1, 2, 3, 4, 5]);
        assert_eq!(r.dropped(), 0);
        assert!(r.is_empty());
    }

    #[test]
    fn overwrites_oldest_and_counts_drops() {
        let mut r = RingBuffer::new(4);
        r.push(&[1, 2, 3, 4]);
        r.push(&[5, 6]); // 1,2 dropped
        assert_eq!(r.dropped(), 2);
        assert_eq!(r.drain(), vec![3, 4, 5, 6]);
    }

    #[test]
    fn giant_push_keeps_freshest_tail() {
        let mut r = RingBuffer::new(4);
        r.push(&[9]);
        let big: Vec<i16> = (0..10).collect();
        r.push(&big);
        assert_eq!(r.drain(), vec![6, 7, 8, 9]);
        // 10-4=6 from the big push + 1 unread already buffered.
        assert_eq!(r.dropped(), 7);
    }

    #[test]
    fn clear_discards_without_counting_drops() {
        let mut r = RingBuffer::new(4);
        r.push(&[1, 2, 3]);
        r.clear();
        assert!(r.is_empty());
        assert_eq!(r.dropped(), 0);
        r.push(&[7]);
        assert_eq!(r.drain(), vec![7]);
    }

    #[test]
    fn snapshot_reads_without_consuming() {
        let mut r = RingBuffer::new(8);
        r.push(&[1, 2, 3]);
        assert_eq!(r.snapshot(), vec![1, 2, 3]);
        // Non-destructive: a second snapshot, and a later push, both still see the data.
        assert_eq!(r.snapshot(), vec![1, 2, 3]);
        r.push(&[4]);
        assert_eq!(r.snapshot(), vec![1, 2, 3, 4]);
        assert_eq!(r.drain(), vec![1, 2, 3, 4]);
        assert!(r.snapshot().is_empty());
    }

    #[test]
    fn wraparound_after_drain_stays_chronological() {
        let mut r = RingBuffer::new(4);
        r.push(&[1, 2, 3, 4]);
        assert_eq!(r.drain(), vec![1, 2, 3, 4]);
        r.push(&[5, 6, 7, 8, 9]); // wraps
        assert_eq!(r.drain(), vec![6, 7, 8, 9]);
    }
}
