//! Instant-pass scheduling policy (§12.3 strategy B), shared by every interpreter so the
//! cadence of live partials can't diverge between the headless [`Pipeline`](crate::Pipeline)
//! and the FFI core loop (§16.2). Pure bookkeeping — no clocks, no I/O, no ASR — driven purely
//! by how much audio has arrived.
//!
//! Policy: fire a partial once at least `min_window` samples exist and `stride` fresh samples
//! have accumulated since the last one, and only while no partial is still in flight (partials
//! are coalesced — a slow decode never queues a backlog; the next one just covers more audio).

/// 16 kHz mono. Emit a partial roughly every 0.4 s of new audio, once ≥ 0.3 s exists.
pub const DEFAULT_STRIDE_SAMPLES: usize = 16_000 * 2 / 5; // 6_400
pub const DEFAULT_MIN_WINDOW_SAMPLES: usize = 16_000 * 3 / 10; // 4_800

#[derive(Debug, Clone)]
pub struct PartialScheduler {
    stride: usize,
    min_window: usize,
    total: usize,
    since_last: usize,
    inflight: bool,
}

impl Default for PartialScheduler {
    fn default() -> Self {
        Self::new(DEFAULT_STRIDE_SAMPLES, DEFAULT_MIN_WINDOW_SAMPLES)
    }
}

impl PartialScheduler {
    pub fn new(stride: usize, min_window: usize) -> Self {
        Self {
            stride: stride.max(1),
            min_window,
            total: 0,
            since_last: 0,
            inflight: false,
        }
    }

    /// New utterance boundary: forget all accumulated audio and any in-flight partial.
    pub fn reset(&mut self) {
        self.total = 0;
        self.since_last = 0;
        self.inflight = false;
    }

    /// Account for `samples` of freshly captured audio; returns `true` when the caller should
    /// dispatch a partial pass now (over the whole window captured so far). On `true` the
    /// scheduler marks a partial in flight — call [`on_complete`](Self::on_complete) when it
    /// returns.
    pub fn on_audio(&mut self, samples: usize) -> bool {
        self.total += samples;
        self.since_last += samples;
        if !self.inflight && self.total >= self.min_window && self.since_last >= self.stride {
            self.since_last = 0;
            self.inflight = true;
            true
        } else {
            false
        }
    }

    /// A dispatched partial finished (success or failure): clear the in-flight latch so the
    /// next stride can fire.
    pub fn on_complete(&mut self) {
        self.inflight = false;
    }

    pub fn is_inflight(&self) -> bool {
        self.inflight
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn holds_until_min_window() {
        let mut s = PartialScheduler::new(4, 10);
        // stride met repeatedly, but total < min_window → no fire yet.
        assert!(!s.on_audio(4));
        assert!(!s.on_audio(4)); // total 8
        assert!(s.on_audio(4)); // total 12 ≥ 10 and since_last 12 ≥ 4
    }

    #[test]
    fn respects_stride_between_fires() {
        let mut s = PartialScheduler::new(5, 5);
        assert!(s.on_audio(5)); // fires
        s.on_complete();
        assert!(!s.on_audio(2)); // only 2 fresh since last
        assert!(s.on_audio(3)); // now 5 fresh → fires
    }

    #[test]
    fn coalesces_while_inflight() {
        let mut s = PartialScheduler::new(4, 4);
        assert!(s.on_audio(4)); // fires, now inflight
        // More than a stride arrives, but the previous partial hasn't completed: suppress.
        assert!(!s.on_audio(4));
        assert!(!s.on_audio(4));
        s.on_complete();
        // Fresh audio since the last fire has piled up → next call fires immediately.
        assert!(s.on_audio(1));
    }

    #[test]
    fn reset_forgets_everything() {
        let mut s = PartialScheduler::new(4, 4);
        assert!(s.on_audio(8));
        s.reset();
        assert!(!s.is_inflight());
        assert!(!s.on_audio(2)); // below thresholds again
    }
}
