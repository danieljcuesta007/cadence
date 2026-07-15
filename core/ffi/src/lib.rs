//! cadence-ffi — the C-ABI surface native shells drive the core through (§16.2, §23,
//! ADR-0005).
//!
//! The shell is a thin interpreter: it translates OS reality (hotkeys, mic buffers,
//! insertion outcomes) into `cadence_engine_*` calls and receives orchestrator
//! [`Effect`]s as JSON (the `cadence-ipc` schema, verbatim) on a callback. Compute
//! effects (`RunAsr`, `RunCleanup`) and ring-buffer bookkeeping are interpreted
//! in-core, on core-owned threads, so every shell gets identical pipeline behavior;
//! only presentation + insertion effects cross the boundary.
//!
//! Threading (§16.3): `push_audio` writes into the ring on the caller's (audio)
//! thread; the orchestrator runs on its own thread; ASR decodes on a worker thread
//! so cancel stays responsive mid-decode. The effect callback fires on the
//! orchestrator thread — shells must trampoline to their UI thread.
//!
//! No-lost-words drain contract (AC-5/AC-22): on `TriggerUp` the core holds the ASR
//! window open until the shell confirms `capture_stopped` (its last buffer is in the
//! ring), with a 500 ms fallback so a wedged shell can't hang the utterance.

use std::cell::RefCell;
use std::collections::VecDeque;
use std::ffi::{c_char, c_void, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use cadence_asr::{pcm_i16_to_f32, AsrEngine, AsrError, MockAsr};
use cadence_cleanup::{CleanupEngine, Guarded, RuleCleanup};
use cadence_ipc::{
    Effect, Event, InsertionOutcome, InsertionStrategy, Mode, ProcessingLocation,
    ProcessingPolicy, State, UtteranceId,
};
use cadence_orchestrator::{Orchestrator, PartialScheduler, RingBuffer};

/// 60 s of 16 kHz mono i16 — the PTT window bound; older audio is dropped (and counted).
const RING_CAPACITY: usize = 16_000 * 60;
/// How long the core waits for the shell's `capture_stopped` before draining anyway.
const CAPTURE_STOP_GRACE: Duration = Duration::from_millis(500);

pub type EffectCallback = unsafe extern "C" fn(effect_json: *const c_char, ctx: *mut c_void);

enum Control {
    Event(Event),
    CaptureStopped,
    /// An instant-pass decode finished on the ASR worker: `Some((utt, text))` on success,
    /// `None` on empty/failure. Either way it clears the scheduler's in-flight latch.
    PartialComplete(Option<(UtteranceId, String)>),
    Shutdown,
}

/// Work handed to the ASR worker. `Partial` is the instant pass over a growing snapshot
/// (§12.3); `Final` is the authoritative refined pass over the drained window.
enum AsrJob {
    Partial { utterance: UtteranceId, window: Vec<i16> },
    Final { utterance: UtteranceId, window: Vec<i16> },
}

impl AsrJob {
    fn utterance(&self) -> &UtteranceId {
        match self {
            AsrJob::Partial { utterance, .. } | AsrJob::Final { utterance, .. } => utterance,
        }
    }
}

pub struct Engine {
    tx: Sender<Control>,
    ring: Arc<Mutex<RingBuffer>>,
    orch_thread: Option<JoinHandle<()>>,
    asr_thread: Option<JoinHandle<()>>,
}

struct OrchLoop {
    machine: Orchestrator,
    cleanup: Guarded<RuleCleanup>,
    ring: Arc<Mutex<RingBuffer>>,
    asr_tx: Sender<AsrJob>,
    cb: EffectCallback,
    /// Callback context as usize so the loop is Send; the shell guarantees validity
    /// for the engine's lifetime.
    ctx: usize,
    pending_drain: Option<(UtteranceId, Instant)>,
    /// Instant-pass cadence (§12.3), shared policy with the headless pipeline.
    partials: PartialScheduler,
    /// The utterance currently capturing, so partial jobs can be tagged. Set on StartCapture,
    /// cleared when the machine leaves Listening.
    listening_utt: Option<UtteranceId>,
}

impl OrchLoop {
    fn run(mut self, rx: Receiver<Control>) {
        loop {
            let msg = if let Some((_, since)) = &self.pending_drain {
                let budget = CAPTURE_STOP_GRACE.saturating_sub(since.elapsed());
                match rx.recv_timeout(budget) {
                    Ok(m) => m,
                    Err(RecvTimeoutError::Timeout) => Control::CaptureStopped,
                    Err(RecvTimeoutError::Disconnected) => return,
                }
            } else {
                match rx.recv() {
                    Ok(m) => m,
                    Err(_) => return,
                }
            };
            match msg {
                Control::Event(ev) => {
                    // Note the audio size before `pump` consumes the event, so a partial can be
                    // scheduled once the machine has (still) settled in Listening.
                    let audio = if let Event::AudioCaptured { samples, .. } = &ev {
                        Some(*samples)
                    } else {
                        None
                    };
                    self.pump(ev);
                    if let Some(samples) = audio {
                        self.maybe_dispatch_partial(samples);
                    }
                }
                Control::CaptureStopped => self.drain_to_asr(),
                Control::PartialComplete(partial) => {
                    self.partials.on_complete();
                    if let Some((utterance, text)) = partial {
                        // The machine drops this if we've already left Listening (stale partial).
                        self.pump(Event::AsrPartial { utterance, text });
                    }
                }
                Control::Shutdown => return,
            }
        }
    }

    /// On cadence, snapshot the growing window and hand a partial decode to the ASR worker.
    /// Only while Listening, and only one partial in flight at a time (the scheduler coalesces).
    fn maybe_dispatch_partial(&mut self, samples: usize) {
        if self.machine.state() != State::Listening {
            return;
        }
        let Some(utterance) = self.listening_utt.clone() else {
            return;
        };
        if self.partials.on_audio(samples) {
            let window = self.ring.lock().unwrap().snapshot();
            if self
                .asr_tx
                .send(AsrJob::Partial { utterance, window })
                .is_err()
            {
                // Worker gone (shutdown): don't leave the latch stuck.
                self.partials.on_complete();
            }
        }
    }

    fn drain_to_asr(&mut self) {
        if let Some((utterance, _)) = self.pending_drain.take() {
            let window = self.ring.lock().unwrap().drain();
            let _ = self.asr_tx.send(AsrJob::Final { utterance, window });
        }
    }

    /// Handle one event plus everything it synchronously cascades into (cleanup runs
    /// inline — it's sub-millisecond; ASR never blocks this loop).
    fn pump(&mut self, first: Event) {
        let mut q = VecDeque::new();
        q.push_back(first);
        while let Some(ev) = q.pop_front() {
            for effect in self.machine.handle(ev) {
                match effect {
                    Effect::StartCapture { utterance } => {
                        // New utterance is now capturing: reset the instant-pass cadence and
                        // remember the id so partial jobs can be tagged.
                        self.listening_utt = Some(utterance.clone());
                        self.partials.reset();
                        self.emit(&Effect::StartCapture { utterance });
                    }
                    Effect::RunAsr { utterance, .. } => {
                        self.pending_drain = Some((utterance, Instant::now()));
                    }
                    Effect::RunCleanup {
                        utterance,
                        transcript,
                        verbatim,
                        ..
                    } => {
                        let ev = match self.cleanup.cleanup(&transcript, verbatim) {
                            Ok(out) => Event::CleanupDone {
                                utterance,
                                text: out.text,
                                location: ProcessingLocation::Local,
                                guard_fallback: out.guard_fallback,
                            },
                            Err(_) => Event::CleanupFailed {
                                utterance,
                                location: ProcessingLocation::Local,
                            },
                        };
                        q.push_back(ev);
                    }
                    // NOTE: StartCapture must NOT clear the ring here — instant-start
                    // audio (AC-5) may already be flowing in from the caller thread by
                    // the time this effect is processed. Stale-tail clearing happens
                    // synchronously in `cadence_engine_trigger_down` instead.
                    Effect::DiscardCapture => {
                        self.ring.lock().unwrap().clear();
                        self.pending_drain = None;
                        self.emit(&effect);
                    }
                    other => self.emit(&other),
                }
            }
        }
    }

    fn emit(&self, effect: &Effect) {
        let json = serde_json::to_string(effect).expect("ipc effects always serialize");
        let c = CString::new(json).expect("json has no interior NUL");
        unsafe { (self.cb)(c.as_ptr(), self.ctx as *mut c_void) }
    }
}

fn debug_log(msg: &str) {
    if std::env::var_os("CADENCE_DEBUG").is_some() {
        eprintln!("[cadence-core] {msg}");
    }
}

fn asr_worker(mut engine: Box<dyn AsrEngine + Send>, rx: Receiver<AsrJob>, tx: Sender<Control>) {
    // Warm the Metal pipeline (encode + both decode paths) once, so the user's first partial
    // isn't the slow cold one (ADR-0006). Silence → Empty is the expected, ignored result.
    let warm = vec![0.0f32; 8_000];
    let _ = engine.transcribe(&warm);
    let _ = engine.transcribe_partial(&warm);
    engine.reset_stream();

    let mut last_utt: Option<UtteranceId> = None;
    while let Ok(job) = rx.recv() {
        // Utterance boundary: drop stale instant-pass stream state before the new one's partials.
        if last_utt.as_ref() != Some(job.utterance()) {
            engine.reset_stream();
            last_utt = Some(job.utterance().clone());
        }
        match job {
            AsrJob::Partial { utterance, window } => {
                let result = engine.transcribe_partial(&pcm_i16_to_f32(&window));
                let partial = match result {
                    Ok(t) => t.instant.map(|text| (utterance, text)),
                    Err(_) => None,
                };
                if tx.send(Control::PartialComplete(partial)).is_err() {
                    return;
                }
            }
            AsrJob::Final { utterance, window } => {
                let t = Instant::now();
                debug_log(&format!("asr job {} ({} samples)", utterance.0, window.len()));
                let result = engine.transcribe(&pcm_i16_to_f32(&window));
                debug_log(&format!(
                    "asr done {} in {} ms (ok={})",
                    utterance.0,
                    t.elapsed().as_millis(),
                    result.is_ok()
                ));
                let ev = match result {
                    Ok(t) => Event::AsrFinal {
                        utterance,
                        transcript: t,
                        location: ProcessingLocation::Local,
                    },
                    Err(AsrError::Empty) => Event::AsrFailed {
                        utterance,
                        location: ProcessingLocation::Local,
                        empty: true,
                    },
                    Err(_) => Event::AsrFailed {
                        utterance,
                        location: ProcessingLocation::Local,
                        empty: false,
                    },
                };
                if tx.send(Control::Event(ev)).is_err() {
                    return;
                }
            }
        }
    }
}

impl Engine {
    fn start(asr: Box<dyn AsrEngine + Send>, cb: EffectCallback, ctx: *mut c_void) -> Engine {
        let ring = Arc::new(Mutex::new(RingBuffer::new(RING_CAPACITY)));
        let (tx, rx) = channel::<Control>();
        let (asr_tx, asr_rx) = channel::<AsrJob>();

        let asr_thread = {
            let tx = tx.clone();
            std::thread::Builder::new()
                .name("cadence-asr".into())
                .spawn(move || asr_worker(asr, asr_rx, tx))
                .expect("spawn asr thread")
        };
        let orch_thread = {
            let orch = OrchLoop {
                machine: Orchestrator::new(),
                cleanup: Guarded::new(RuleCleanup::default()),
                ring: Arc::clone(&ring),
                asr_tx,
                cb,
                ctx: ctx as usize,
                pending_drain: None,
                partials: PartialScheduler::default(),
                listening_utt: None,
            };
            std::thread::Builder::new()
                .name("cadence-orchestrator".into())
                .spawn(move || orch.run(rx))
                .expect("spawn orchestrator thread")
        };

        Engine {
            tx,
            ring,
            orch_thread: Some(orch_thread),
            asr_thread: Some(asr_thread),
        }
    }

    fn send(&self, msg: Control) {
        // A closed channel means shutdown is in progress; dropping the message is fine.
        let _ = self.tx.send(msg);
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        let _ = self.tx.send(Control::Shutdown);
        if let Some(t) = self.orch_thread.take() {
            let _ = t.join(); // dropping OrchLoop drops asr_tx → worker's recv fails → exits
        }
        if let Some(t) = self.asr_thread.take() {
            let _ = t.join();
        }
    }
}

// --------------------------------------------------------------------------------------------
// C ABI

thread_local! {
    static LAST_ERROR: RefCell<Option<CString>> = const { RefCell::new(None) };
}

fn set_last_error(msg: String) {
    LAST_ERROR.with(|e| {
        *e.borrow_mut() = Some(CString::new(msg).unwrap_or_default());
    });
}

/// Last error message for the calling thread, or NULL. Valid until the next failing
/// call on the same thread.
#[no_mangle]
pub extern "C" fn cadence_last_error() -> *const c_char {
    LAST_ERROR.with(|e| {
        e.borrow()
            .as_ref()
            .map(|c| c.as_ptr())
            .unwrap_or(std::ptr::null())
    })
}

#[no_mangle]
pub extern "C" fn cadence_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr() as *const c_char
}

/// Verify a model file's SHA-256 against `expected_sha256_hex` (lowercase hex). Returns true
/// iff the file hashes to the expected value. On mismatch or I/O error returns false and sets
/// `cadence_last_error`. Lets the shell gate `cadence_engine_new` on integrity before loading a
/// model (§17.5) — the registry/rollback logic lives in `cadence-models`. Streams the file, so
/// it is safe on a ~140 MB model.
#[no_mangle]
pub unsafe extern "C" fn cadence_model_verify(
    model_path: *const c_char,
    expected_sha256_hex: *const c_char,
) -> bool {
    guarded("cadence_model_verify", || {
        let (Some(path), Some(expected)) =
            (cstr_arg(model_path), cstr_arg(expected_sha256_hex))
        else {
            set_last_error("cadence_model_verify: NULL/invalid argument".into());
            return false;
        };
        let expected = expected.to_lowercase();
        match cadence_models::sha256_file(std::path::Path::new(&path)) {
            Ok(actual) if actual == expected => true,
            Ok(actual) => {
                set_last_error(format!(
                    "model hash mismatch ({path}): expected {expected}, got {actual}"
                ));
                false
            }
            Err(e) => {
                set_last_error(format!("model verify ({path}): {e}"));
                false
            }
        }
    })
    .unwrap_or(false)
}

unsafe fn cstr_arg(p: *const c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    CStr::from_ptr(p).to_str().ok().map(|s| s.to_string())
}

fn guarded<T>(what: &str, f: impl FnOnce() -> T) -> Option<T> {
    // Panics must not unwind across the FFI boundary.
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(v) => Some(v),
        Err(_) => {
            set_last_error(format!("panic in {what}"));
            None
        }
    }
}

/// Create an engine backed by whisper.cpp at `model_path` (requires the `whisper`
/// feature). Returns NULL on failure — see `cadence_last_error`.
#[no_mangle]
pub unsafe extern "C" fn cadence_engine_new(
    model_path: *const c_char,
    cb: EffectCallback,
    ctx: *mut c_void,
) -> *mut Engine {
    guarded("cadence_engine_new", || {
        let Some(path) = cstr_arg(model_path) else {
            set_last_error("model_path is NULL or not UTF-8".into());
            return std::ptr::null_mut();
        };
        #[cfg(feature = "whisper")]
        {
            match cadence_asr::whisper::WhisperAsr::load(&path) {
                Ok(asr) => Box::into_raw(Box::new(Engine::start(Box::new(asr), cb, ctx))),
                Err(e) => {
                    set_last_error(format!("whisper load ({path}): {e}"));
                    std::ptr::null_mut()
                }
            }
        }
        #[cfg(not(feature = "whisper"))]
        {
            let _ = (cb, ctx);
            set_last_error(format!(
                "built without the `whisper` feature (model_path={path})"
            ));
            std::ptr::null_mut()
        }
    })
    .unwrap_or(std::ptr::null_mut())
}

/// Create an engine with a deterministic mock ASR (tests / machines without a model).
#[no_mangle]
pub unsafe extern "C" fn cadence_engine_new_mock(
    refined_text: *const c_char,
    cb: EffectCallback,
    ctx: *mut c_void,
) -> *mut Engine {
    guarded("cadence_engine_new_mock", || {
        let refined = cstr_arg(refined_text).unwrap_or_else(|| "mock transcript".into());
        let asr = MockAsr { refined };
        Box::into_raw(Box::new(Engine::start(Box::new(asr), cb, ctx)))
    })
    .unwrap_or(std::ptr::null_mut())
}

/// Destroy the engine. Blocks briefly joining core threads. No callbacks fire after
/// this returns.
#[no_mangle]
pub unsafe extern "C" fn cadence_engine_free(engine: *mut Engine) {
    if engine.is_null() {
        return;
    }
    guarded("cadence_engine_free", || {
        drop(Box::from_raw(engine));
    });
}

macro_rules! with_engine {
    ($name:literal, $engine:ident, $body:expr) => {{
        if $engine.is_null() {
            set_last_error(concat!($name, ": engine is NULL").into());
            return;
        }
        let $engine = &*$engine;
        guarded($name, || $body);
    }};
}

/// PTT down (or hands-free start). Phase 1: policy is always local-only (§19).
#[no_mangle]
pub unsafe extern "C" fn cadence_engine_trigger_down(engine: *mut Engine, verbatim: bool) {
    with_engine!("cadence_engine_trigger_down", engine, {
        // Clear any stale tail from the previous utterance NOW, on the caller thread:
        // audio pushed after this call belongs to this utterance and must survive even
        // if the orchestrator hasn't processed TriggerDown yet (AC-5 instant start).
        engine.ring.lock().unwrap().clear();
        engine.send(Control::Event(Event::TriggerDown {
            mode: if verbatim {
                Mode::Verbatim
            } else {
                Mode::Dictation
            },
            policy: ProcessingPolicy::LocalOnly,
        }));
    });
}

#[no_mangle]
pub unsafe extern "C" fn cadence_engine_trigger_up(engine: *mut Engine) {
    with_engine!("cadence_engine_trigger_up", engine, {
        engine.send(Control::Event(Event::TriggerUp));
    });
}

#[no_mangle]
pub unsafe extern "C" fn cadence_engine_cancel(engine: *mut Engine) {
    with_engine!("cadence_engine_cancel", engine, {
        engine.send(Control::Event(Event::Cancel));
    });
}

/// Shell confirmation that capture is stopped and its final buffer has been pushed.
/// Unblocks the ASR window drain (see module docs).
#[no_mangle]
pub unsafe extern "C" fn cadence_engine_capture_stopped(engine: *mut Engine) {
    with_engine!("cadence_engine_capture_stopped", engine, {
        engine.send(Control::CaptureStopped);
    });
}

/// Append captured PCM (16 kHz mono i16) to the ring buffer. Safe to call from the
/// audio callback thread; `level` (0..1) drives the waveform.
#[no_mangle]
pub unsafe extern "C" fn cadence_engine_push_audio(
    engine: *mut Engine,
    samples: *const i16,
    len: usize,
    level: f32,
) {
    if engine.is_null() || (samples.is_null() && len > 0) {
        set_last_error("cadence_engine_push_audio: NULL argument".into());
        return;
    }
    let engine = &*engine;
    let slice = std::slice::from_raw_parts(samples, len);
    guarded("cadence_engine_push_audio", || {
        engine.ring.lock().unwrap().push(slice);
        engine.send(Control::Event(Event::AudioCaptured {
            samples: len,
            level,
        }));
    });
}

/// Report the outcome of a `run_insertion` effect. `strategy` is the ipc snake_case
/// name: "direct" | "tsf" | "paste_restore" | "clipboard_notify".
#[no_mangle]
pub unsafe extern "C" fn cadence_engine_insertion_result(
    engine: *mut Engine,
    utterance_id: *const c_char,
    strategy: *const c_char,
    inserted: bool,
    clipboard_restored: bool,
) {
    with_engine!("cadence_engine_insertion_result", engine, {
        let (Some(utt), Some(strat)) = (cstr_arg(utterance_id), cstr_arg(strategy)) else {
            set_last_error("cadence_engine_insertion_result: NULL/invalid string".into());
            return;
        };
        let Ok(strategy) = serde_json::from_str::<InsertionStrategy>(&format!("\"{strat}\""))
        else {
            set_last_error(format!("unknown insertion strategy: {strat}"));
            return;
        };
        engine.send(Control::Event(Event::InsertionCompleted {
            utterance: UtteranceId(utt),
            outcome: InsertionOutcome {
                strategy,
                inserted,
                clipboard_restored,
            },
        }));
    });
}

/// Report that every strategy above clipboard-notify failed.
#[no_mangle]
pub unsafe extern "C" fn cadence_engine_insertion_failed(
    engine: *mut Engine,
    utterance_id: *const c_char,
) {
    with_engine!("cadence_engine_insertion_failed", engine, {
        let Some(utt) = cstr_arg(utterance_id) else {
            set_last_error("cadence_engine_insertion_failed: NULL/invalid string".into());
            return;
        };
        engine.send(Control::Event(Event::InsertionFailed {
            utterance: UtteranceId(utt),
        }));
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;
    use std::time::Duration;

    /// Test callback: ctx is a leaked `Sender<String>`; effects flow back as JSON.
    unsafe extern "C" fn collect_cb(json: *const c_char, ctx: *mut c_void) {
        let tx = &*(ctx as *const mpsc::Sender<String>);
        let s = CStr::from_ptr(json).to_str().unwrap().to_string();
        let _ = tx.send(s);
    }

    struct Harness {
        engine: *mut Engine,
        rx: mpsc::Receiver<String>,
        _tx: Box<mpsc::Sender<String>>,
    }

    impl Harness {
        fn new() -> Self {
            let (tx, rx) = mpsc::channel::<String>();
            let tx = Box::new(tx);
            let ctx = &*tx as *const mpsc::Sender<String> as *mut c_void;
            let refined = CString::new("um hello world this is uh cadence").unwrap();
            let engine = unsafe { cadence_engine_new_mock(refined.as_ptr(), collect_cb, ctx) };
            assert!(!engine.is_null());
            Self {
                engine,
                rx,
                _tx: tx,
            }
        }

        /// Wait for the next effect whose `type` matches, collecting along the way.
        fn expect(&self, ty: &str) -> serde_json::Value {
            self.expect_timeout(ty, Duration::from_secs(3))
        }

        fn expect_timeout(&self, ty: &str, timeout: Duration) -> serde_json::Value {
            let deadline = Instant::now() + timeout;
            loop {
                let remaining = deadline
                    .checked_duration_since(Instant::now())
                    .expect(&format!("timed out waiting for effect `{ty}`"));
                let s = self.rx.recv_timeout(remaining).unwrap_or_else(|_| {
                    panic!("timed out waiting for effect `{ty}`");
                });
                let v: serde_json::Value = serde_json::from_str(&s).unwrap();
                if v["type"] == ty {
                    return v;
                }
            }
        }

        fn assert_no_effect(&self, ty: &str, within: Duration) {
            let deadline = Instant::now() + within;
            while let Some(rem) = deadline.checked_duration_since(Instant::now()) {
                match self.rx.recv_timeout(rem) {
                    Ok(s) => {
                        let v: serde_json::Value = serde_json::from_str(&s).unwrap();
                        assert_ne!(v["type"], ty, "unexpected effect: {s}");
                    }
                    Err(_) => return,
                }
            }
        }
    }

    impl Drop for Harness {
        fn drop(&mut self) {
            unsafe { cadence_engine_free(self.engine) };
        }
    }

    fn push_chunk(h: &Harness, samples: usize) {
        let pcm = vec![100i16; samples];
        unsafe { cadence_engine_push_audio(h.engine, pcm.as_ptr(), pcm.len(), 0.5) };
    }

    #[test]
    fn full_utterance_over_ffi_reaches_insertion_with_cleaned_text() {
        let h = Harness::new();
        unsafe { cadence_engine_trigger_down(h.engine, false) };
        h.expect("start_capture");
        push_chunk(&h, 1600);
        push_chunk(&h, 1600);
        unsafe { cadence_engine_trigger_up(h.engine) };
        h.expect("stop_capture");
        unsafe { cadence_engine_capture_stopped(h.engine) };

        let ins = h.expect("run_insertion");
        let text = ins["text"].as_str().unwrap();
        assert!(!text.contains("um") && !text.contains("uh"), "fillers survived: {text}");
        assert!(text.starts_with("Hello"), "casing not applied: {text}");

        let utt = ins["utterance"].as_str().unwrap();
        let utt_c = CString::new(utt).unwrap();
        let strat = CString::new("direct").unwrap();
        unsafe {
            cadence_engine_insertion_result(h.engine, utt_c.as_ptr(), strat.as_ptr(), true, true)
        };
        let overlay = h.expect("show_overlay");
        assert_eq!(overlay["state"], "done");
        h.expect("persist_utterance");
        h.expect("schedule_fade_to_idle");
    }

    #[test]
    fn instant_pass_emits_show_partial_while_listening() {
        // §12.3: enough audio to cross the partial stride → the core runs transcribe_partial on
        // the growing window and emits show_partial before the utterance ends. Mock's default
        // partial echoes its refined text.
        let h = Harness::new();
        unsafe { cadence_engine_trigger_down(h.engine, false) };
        h.expect("start_capture");
        // 8 × 1600 = 12 800 samples, well past the 6 400-sample stride.
        for _ in 0..8 {
            push_chunk(&h, 1600);
        }
        let partial = h.expect("show_partial");
        assert!(
            partial["text"].as_str().unwrap().contains("hello"),
            "unexpected partial text: {partial}"
        );
        // The utterance still finishes through the refined pass.
        unsafe { cadence_engine_trigger_up(h.engine) };
        h.expect("stop_capture");
        unsafe { cadence_engine_capture_stopped(h.engine) };
        h.expect("run_insertion");
    }

    #[test]
    fn cancel_discards_capture_and_never_inserts() {
        let h = Harness::new();
        unsafe { cadence_engine_trigger_down(h.engine, false) };
        h.expect("start_capture");
        push_chunk(&h, 1600);
        unsafe { cadence_engine_cancel(h.engine) };
        h.expect("discard_capture");
        h.assert_no_effect("run_insertion", Duration::from_millis(300));
    }

    #[test]
    fn missing_capture_stopped_confirmation_drains_after_grace() {
        let h = Harness::new();
        unsafe { cadence_engine_trigger_down(h.engine, false) };
        h.expect("start_capture");
        push_chunk(&h, 1600);
        unsafe { cadence_engine_trigger_up(h.engine) };
        // No capture_stopped: the 500 ms grace must fire and complete the utterance.
        let ins = h.expect("run_insertion");
        assert!(ins["text"].as_str().unwrap().starts_with("Hello"));
    }

    #[test]
    fn late_audio_buffer_lands_before_confirmed_drain() {
        let h = Harness::new();
        unsafe { cadence_engine_trigger_down(h.engine, false) };
        h.expect("start_capture");
        push_chunk(&h, 1600);
        unsafe { cadence_engine_trigger_up(h.engine) };
        h.expect("stop_capture");
        // The in-flight buffer arrives after TriggerUp but before the shell confirms:
        // it must be part of the ASR window (mock can't verify contents, but this
        // asserts the ordering contract doesn't drop or crash).
        push_chunk(&h, 800);
        unsafe { cadence_engine_capture_stopped(h.engine) };
        h.expect("run_insertion");
    }

    /// Reports the exact window size it was given — lets tests pin no-lost-words.
    struct CountingAsr;
    impl AsrEngine for CountingAsr {
        fn transcribe(
            &mut self,
            pcm: &[f32],
        ) -> Result<cadence_ipc::Transcript, cadence_asr::AsrError> {
            Ok(cadence_ipc::Transcript {
                instant: None,
                refined: format!("window {} samples", pcm.len()),
                language: Some("en".into()),
            })
        }
    }

    #[test]
    fn instant_start_audio_pushed_before_start_capture_is_never_lost() {
        // Regression: the core used to clear the ring while processing StartCapture on
        // the orchestrator thread, racing (and eating) instant-start audio pushed right
        // after trigger_down from the caller thread (found live: 8 000 of 56 235 samples
        // lost → mangled leading words).
        let (tx, rx) = mpsc::channel::<String>();
        let tx = Box::new(tx);
        let ctx = &*tx as *const mpsc::Sender<String> as *mut c_void;
        let engine = Box::into_raw(Box::new(Engine::start(
            Box::new(CountingAsr),
            collect_cb,
            ctx,
        )));
        let h = Harness {
            engine,
            rx,
            _tx: tx,
        };
        unsafe { cadence_engine_trigger_down(h.engine, false) };
        // Push immediately — do NOT wait for the start_capture effect.
        push_chunk(&h, 1600);
        push_chunk(&h, 1600);
        push_chunk(&h, 1600);
        unsafe { cadence_engine_trigger_up(h.engine) };
        h.expect("stop_capture");
        unsafe { cadence_engine_capture_stopped(h.engine) };
        let ins = h.expect("run_insertion");
        let text = ins["text"].as_str().unwrap();
        assert!(
            text.contains("4800 samples"),
            "leading audio was lost: {text}"
        );
    }

    /// End-to-end over the real whisper engine (no mic): a fixture WAV pushed through the C ABI
    /// must surface a live partial *and* the refined insert. Skips if the model isn't fetched.
    #[cfg(feature = "whisper")]
    #[test]
    fn instant_pass_over_real_whisper_emits_partial_then_final() {
        use std::path::PathBuf;

        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
        let model = root.join("models/artifacts/ggml-base.en.bin");
        if !model.exists() {
            eprintln!("skip: {} not present (run models/fetch-models.sh)", model.display());
            return;
        }
        // Canonical 16 kHz mono PCM16 fixture; skip the 44-byte header.
        let wav_bytes = std::fs::read(root.join("qa/fixtures/hello.wav")).unwrap();
        let pcm: Vec<i16> = wav_bytes[44..]
            .chunks_exact(2)
            .map(|b| i16::from_le_bytes([b[0], b[1]]))
            .collect();

        let (tx, rx) = mpsc::channel::<String>();
        let tx = Box::new(tx);
        let ctx = &*tx as *const mpsc::Sender<String> as *mut c_void;
        let model_c = CString::new(model.to_str().unwrap()).unwrap();
        let engine = unsafe { cadence_engine_new(model_c.as_ptr(), collect_cb, ctx) };
        assert!(!engine.is_null(), "whisper engine failed to load");
        let h = Harness { engine, rx, _tx: tx };

        unsafe { cadence_engine_trigger_down(h.engine, false) };
        h.expect("start_capture");
        // Feed ~100 ms chunks like the mic callback, with a small gap so the instant pass runs.
        for chunk in pcm.chunks(1600) {
            unsafe { cadence_engine_push_audio(h.engine, chunk.as_ptr(), chunk.len(), 0.5) };
            std::thread::sleep(Duration::from_millis(3));
        }
        // Warmup + first decode can be slow on a cold model → generous window.
        let partial = h.expect_timeout("show_partial", Duration::from_secs(15));
        let ptext = partial["text"].as_str().unwrap().to_lowercase();
        assert!(ptext.contains("hello"), "partial lacked expected words: {ptext}");

        unsafe { cadence_engine_trigger_up(h.engine) };
        h.expect("stop_capture");
        unsafe { cadence_engine_capture_stopped(h.engine) };
        let ins = h.expect_timeout("run_insertion", Duration::from_secs(10));
        let ftext = ins["text"].as_str().unwrap().to_lowercase();
        // Reliably-transcribed words on this fixture (base.en garbles "cadence dictation" into
        // "cade instictation" — see ADR-0006 — so assert on the stable words, not those).
        assert!(
            ftext.contains("hello") && ftext.contains("test") && ftext.contains("pipeline"),
            "refined text unexpected: {ftext}"
        );
    }

    #[test]
    fn model_verify_accepts_match_and_rejects_tamper() {
        let content = b"pretend model weights";
        let mut path = std::env::temp_dir();
        path.push(format!("cadence-ffi-verify-{}", std::process::id()));
        std::fs::write(&path, content).unwrap();
        let path_c = CString::new(path.to_str().unwrap()).unwrap();

        let good = cadence_models::sha256::sha256_hex(content);
        let good_c = CString::new(good).unwrap();
        assert!(unsafe { cadence_model_verify(path_c.as_ptr(), good_c.as_ptr()) });

        let bad_c = CString::new("0".repeat(64)).unwrap();
        assert!(!unsafe { cadence_model_verify(path_c.as_ptr(), bad_c.as_ptr()) });
        // last_error is populated on failure.
        let err = unsafe { CStr::from_ptr(cadence_last_error()) }.to_str().unwrap();
        assert!(err.contains("mismatch"), "unexpected error: {err}");

        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn new_engine_reports_version() {
        let v = unsafe { CStr::from_ptr(cadence_version()) };
        assert!(!v.to_str().unwrap().is_empty());
    }
}
