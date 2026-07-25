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
    /// Decode-language override the shell can flip at runtime (menu toggle → the store's
    /// `dictation_language`). Empty = leave the engine on whatever it loaded with (env
    /// `CADENCE_LANG`, default "auto"). Shared with the ASR worker, which reads it before
    /// each decode. Language is a per-decode whisper parameter, so a flip is instant — no
    /// model reload.
    lang: Arc<Mutex<String>>,
    /// Personal-dictionary bias (whisper initial_prompt) the shell sets from the stored
    /// vocabulary. Shared with the ASR worker like `lang`; applied before each decode.
    prompt: Arc<Mutex<String>>,
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
            let mut window = self.ring.lock().unwrap().snapshot();
            // Sliding tail (§12.3): long dictations decode only the recent window, keeping
            // each partial O(tail) and inside the capped encoder's coverage.
            let start = self.partials.window_start(window.len());
            if start > 0 {
                window.drain(..start);
            }
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

/// Rebuilds the ASR engine after an idle unload. Must produce an engine configured
/// identically to the initial one (audio_ctx cap included).
type AsrFactory = Box<dyn Fn() -> Result<Box<dyn AsrEngine + Send>, String> + Send>;

/// Idle model unload (§28 idle-RAM budget, ADR-0006): after this long with no ASR work the
/// worker drops the engine (~200 MB of model + Metal buffers); the next dictation reloads
/// transparently (~200–500 ms warm, worn as a longer "thinking" — capture is unaffected,
/// audio waits in the ring). Env `CADENCE_UNLOAD_SECS` overrides; 0 disables.
const DEFAULT_UNLOAD_AFTER: Duration = Duration::from_secs(300);

fn unload_after_config() -> Option<Duration> {
    match std::env::var("CADENCE_UNLOAD_SECS").ok().and_then(|v| v.parse::<u64>().ok()) {
        Some(0) => None,
        Some(secs) => Some(Duration::from_secs(secs)),
        None => Some(DEFAULT_UNLOAD_AFTER),
    }
}

/// Warm the Metal pipeline (encode + both decode paths) once, so the user's first partial
/// isn't the slow cold one (ADR-0006). Silence → Empty is the expected, ignored result.
fn warm_engine(engine: &mut Box<dyn AsrEngine + Send>) {
    let warm = vec![0.0f32; 8_000];
    let _ = engine.transcribe(&warm);
    let _ = engine.transcribe_partial(&warm);
    engine.reset_stream();
}

fn asr_worker(
    engine: Box<dyn AsrEngine + Send>,
    factory: AsrFactory,
    unload_after: Option<Duration>,
    rx: Receiver<AsrJob>,
    tx: Sender<Control>,
    lang: Arc<Mutex<String>>,
    prompt: Arc<Mutex<String>>,
) {
    let mut engine = Some(engine);
    warm_engine(engine.as_mut().expect("initial engine"));

    // Apply the shell's runtime overrides (language + dictionary prompt) to `e`. Called before
    // every decode and after a reload so the choices survive idle unload. Empty = leave as-is.
    let apply_overrides = |e: &mut Box<dyn AsrEngine + Send>| {
        if let Ok(l) = lang.lock() {
            if !l.is_empty() {
                e.set_language(&l);
            }
        }
        if let Ok(p) = prompt.lock() {
            e.set_prompt(&p); // empty clears the bias — always apply so removals take effect
        }
    };
    apply_overrides(engine.as_mut().expect("initial engine"));

    let mut last_utt: Option<UtteranceId> = None;
    loop {
        let job = match unload_after {
            Some(after) => match rx.recv_timeout(after) {
                Ok(job) => job,
                Err(RecvTimeoutError::Timeout) => {
                    if engine.take().is_some() {
                        debug_log("asr engine unloaded (idle)");
                    }
                    continue;
                }
                Err(RecvTimeoutError::Disconnected) => return,
            },
            None => match rx.recv() {
                Ok(job) => job,
                Err(_) => return,
            },
        };
        let engine = match &mut engine {
            Some(e) => e,
            slot @ None => {
                let t = Instant::now();
                match factory() {
                    Ok(mut e) => {
                        warm_engine(&mut e);
                        apply_overrides(&mut e); // language + dictionary survive idle unload
                        debug_log(&format!("asr engine reloaded in {} ms", t.elapsed().as_millis()));
                        slot.insert(e)
                    }
                    Err(msg) => {
                        // Reload failed (model missing/corrupt): stay unloaded, retry on the
                        // next job. A partial just skips (and releases the scheduler latch);
                        // a final fails the utterance so the no-lost-words path runs.
                        debug_log(&format!("asr engine reload FAILED: {msg}"));
                        let sent = match &job {
                            AsrJob::Partial { .. } => tx.send(Control::PartialComplete(None)),
                            AsrJob::Final { utterance, .. } => {
                                tx.send(Control::Event(Event::AsrFailed {
                                    utterance: utterance.clone(),
                                    location: ProcessingLocation::Local,
                                    empty: false,
                                }))
                            }
                        };
                        if sent.is_err() {
                            return;
                        }
                        continue;
                    }
                }
            }
        };
        // Utterance boundary: drop stale instant-pass stream state before the new one's partials.
        if last_utt.as_ref() != Some(job.utterance()) {
            engine.reset_stream();
            last_utt = Some(job.utterance().clone());
        }
        // Pick up any language/dictionary change the shell made since the last decode.
        apply_overrides(engine);
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
    fn start(
        asr: Box<dyn AsrEngine + Send>,
        factory: AsrFactory,
        cb: EffectCallback,
        ctx: *mut c_void,
    ) -> Engine {
        let ring = Arc::new(Mutex::new(RingBuffer::new(RING_CAPACITY)));
        let (tx, rx) = channel::<Control>();
        let (asr_tx, asr_rx) = channel::<AsrJob>();
        let lang = Arc::new(Mutex::new(String::new()));
        let prompt = Arc::new(Mutex::new(String::new()));

        let asr_thread = {
            let tx = tx.clone();
            let unload_after = unload_after_config();
            let lang = Arc::clone(&lang);
            let prompt = Arc::clone(&prompt);
            std::thread::Builder::new()
                .name("cadence-asr".into())
                .spawn(move || asr_worker(asr, factory, unload_after, asr_rx, tx, lang, prompt))
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
            lang,
            prompt,
        }
    }

    fn send(&self, msg: Control) {
        // A closed channel means shutdown is in progress; dropping the message is fine.
        let _ = self.tx.send(msg);
    }

    fn set_language(&self, lang: &str) {
        if let Ok(mut l) = self.lang.lock() {
            *l = lang.trim().to_lowercase();
        }
    }

    fn set_prompt(&self, prompt: &str) {
        if let Ok(mut p) = self.prompt.lock() {
            *p = prompt.trim().to_string();
        }
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
            let load = |path: &str| -> Result<Box<dyn AsrEngine + Send>, String> {
                let mut asr =
                    cadence_asr::whisper::WhisperAsr::load(path).map_err(|e| e.to_string())?;
                // Instant pass encodes at most the sliding tail — cap the encoder to
                // match (O(tail) per partial instead of the model's full 30 s window).
                asr.set_partial_audio_ctx(cadence_orchestrator::PARTIAL_AUDIO_CTX_FRAMES);
                Ok(Box::new(asr))
            };
            match load(&path) {
                Ok(asr) => {
                    let factory_path = path.clone();
                    let factory: AsrFactory = Box::new(move || load(&factory_path));
                    Box::into_raw(Box::new(Engine::start(asr, factory, cb, ctx)))
                }
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
        let asr = MockAsr {
            refined: refined.clone(),
        };
        let factory: AsrFactory =
            Box::new(move || Ok(Box::new(MockAsr { refined: refined.clone() }) as _));
        Box::into_raw(Box::new(Engine::start(Box::new(asr), factory, cb, ctx)))
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

/// Set the dictation language at runtime: "auto" (detect per utterance; multilingual models
/// only), an ISO code like "en"/"es", or "" to leave the engine on whatever it loaded with.
/// Takes effect on the next decode — language is a per-decode whisper parameter, so no model
/// reload. The choice also survives an idle model unload.
#[no_mangle]
pub unsafe extern "C" fn cadence_engine_set_language(engine: *mut Engine, lang: *const c_char) {
    with_engine!("cadence_engine_set_language", engine, {
        engine.set_language(&cstr_arg(lang).unwrap_or_default());
    });
}

/// Set the personal-dictionary bias: a phrase/list of terms (proper nouns, jargon, names) fed
/// to whisper as `initial_prompt` so they decode with the right spelling. "" clears the bias.
/// Takes effect on the next refined decode; no model reload; survives idle unload.
#[no_mangle]
pub unsafe extern "C" fn cadence_engine_set_vocabulary(engine: *mut Engine, terms: *const c_char) {
    with_engine!("cadence_engine_set_vocabulary", engine, {
        engine.set_prompt(&cstr_arg(terms).unwrap_or_default());
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

// ---- encrypted store (§24) ----------------------------------------------------------
//
// Opaque handle over cadence-store. The shell owns the key (macOS Keychain) and passes raw
// bytes; key material is never persisted here. All calls are panic-fenced like the engine's.

/// Opaque store handle (a `cadence_store::Store` behind a mutex — the shell calls from
/// its main thread and the effect router's queues).
pub struct StoreHandle {
    store: Mutex<cadence_store::Store>,
}

/// Open (or create) the encrypted store. `key` must be 32 bytes from the OS keychain.
/// NULL on failure — see `cadence_last_error` (wrong key reports as such).
#[no_mangle]
pub unsafe extern "C" fn cadence_store_open(
    db_path: *const c_char,
    key: *const u8,
    key_len: usize,
) -> *mut StoreHandle {
    guarded("cadence_store_open", || {
        let Some(path) = cstr_arg(db_path) else {
            set_last_error("db_path is NULL or not UTF-8".into());
            return std::ptr::null_mut();
        };
        if key.is_null() {
            set_last_error("key is NULL".into());
            return std::ptr::null_mut();
        }
        let key = std::slice::from_raw_parts(key, key_len);
        match cadence_store::Store::open(&path, key) {
            Ok(store) => Box::into_raw(Box::new(StoreHandle {
                store: Mutex::new(store),
            })),
            Err(e) => {
                set_last_error(format!("store open ({path}): {e}"));
                std::ptr::null_mut()
            }
        }
    })
    .unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn cadence_store_free(store: *mut StoreHandle) {
    if store.is_null() {
        return;
    }
    guarded("cadence_store_free", || {
        drop(Box::from_raw(store));
    });
}

/// Persist one utterance from the shell's enriched history JSON (the same record the JSONL
/// stand-in received). Returns false on failure — the caller MUST then fall back to JSONL
/// so no words are ever lost (AC-22).
#[no_mangle]
pub unsafe extern "C" fn cadence_store_persist_json(
    store: *mut StoreHandle,
    record_json: *const c_char,
) -> bool {
    if store.is_null() {
        set_last_error("cadence_store_persist_json: store is NULL".into());
        return false;
    }
    guarded("cadence_store_persist_json", || {
        let Some(json) = cstr_arg(record_json) else {
            set_last_error("record_json is NULL or not UTF-8".into());
            return false;
        };
        let store = &*store;
        let result = cadence_store::UtteranceRecord::from_json(&json).and_then(|mut rec| {
            // Session-scoped ids (utt-1, utt-2 …) repeat across launches: qualify by
            // timestamp, same scheme as the JSONL import, so history never collides.
            rec.id = format!("{}-{}", rec.id, rec.created_at_ms);
            store.store.lock().unwrap().insert_utterance(&rec)
        });
        match result {
            Ok(()) => true,
            Err(e) => {
                set_last_error(format!("store persist: {e}"));
                false
            }
        }
    })
    .unwrap_or(false)
}

/// Most recent utterances as a JSON array (dashboard feed), newest first. Caller frees the
/// returned string with `cadence_string_free`. NULL on failure.
#[no_mangle]
pub unsafe extern "C" fn cadence_store_recent_json(
    store: *mut StoreHandle,
    limit: usize,
) -> *mut c_char {
    if store.is_null() {
        set_last_error("cadence_store_recent_json: store is NULL".into());
        return std::ptr::null_mut();
    }
    guarded("cadence_store_recent_json", || {
        let store = &*store;
        match store.store.lock().unwrap().recent_utterances(limit) {
            Ok(rows) => {
                let arr: Vec<serde_json::Value> =
                    rows.iter().map(cadence_store::UtteranceRecord::to_json).collect();
                match CString::new(serde_json::Value::Array(arr).to_string()) {
                    Ok(c) => c.into_raw(),
                    Err(_) => std::ptr::null_mut(),
                }
            }
            Err(e) => {
                set_last_error(format!("store recent: {e}"));
                std::ptr::null_mut()
            }
        }
    })
    .unwrap_or(std::ptr::null_mut())
}

/// One-time JSONL → store migration. Returns the number of records imported, or -1 on
/// failure. Idempotent; the caller renames the JSONL aside only after a non-negative return.
#[no_mangle]
pub unsafe extern "C" fn cadence_store_import_jsonl(
    store: *mut StoreHandle,
    jsonl_path: *const c_char,
) -> i64 {
    if store.is_null() {
        set_last_error("cadence_store_import_jsonl: store is NULL".into());
        return -1;
    }
    guarded("cadence_store_import_jsonl", || {
        let Some(path) = cstr_arg(jsonl_path) else {
            set_last_error("jsonl_path is NULL or not UTF-8".into());
            return -1;
        };
        let store = &*store;
        match store.store.lock().unwrap().import_jsonl(&path) {
            Ok((imported, _skipped)) => imported as i64,
            Err(e) => {
                set_last_error(format!("store import ({path}): {e}"));
                -1
            }
        }
    })
    .unwrap_or(-1)
}

/// Retention (§24): purge utterances older than `days` (≤0 is a no-op). Returns rows
/// purged, or -1 on failure.
#[no_mangle]
pub unsafe extern "C" fn cadence_store_purge_utterances(
    store: *mut StoreHandle,
    days: i64,
) -> i64 {
    if store.is_null() {
        set_last_error("cadence_store_purge_utterances: store is NULL".into());
        return -1;
    }
    guarded("cadence_store_purge_utterances", || {
        let store = &*store;
        match store.store.lock().unwrap().purge_utterances_older_than_days(days) {
            Ok(n) => n as i64,
            Err(e) => {
                set_last_error(format!("purge: {e}"));
                -1
            }
        }
    })
    .unwrap_or(-1)
}

/// Read a settings value (§24 settings KV). NULL when unset or on error (see last_error).
/// Caller frees with `cadence_string_free`.
#[no_mangle]
pub unsafe extern "C" fn cadence_store_setting_get(
    store: *mut StoreHandle,
    key: *const c_char,
) -> *mut c_char {
    if store.is_null() {
        set_last_error("cadence_store_setting_get: store is NULL".into());
        return std::ptr::null_mut();
    }
    guarded("cadence_store_setting_get", || {
        let Some(k) = cstr_arg(key) else {
            set_last_error("key is NULL or not UTF-8".into());
            return std::ptr::null_mut();
        };
        let store = &*store;
        match store.store.lock().unwrap().get_setting(&k) {
            Ok(Some(v)) => CString::new(v).map(CString::into_raw).unwrap_or(std::ptr::null_mut()),
            Ok(None) => std::ptr::null_mut(),
            Err(e) => {
                set_last_error(format!("setting get ({k}): {e}"));
                std::ptr::null_mut()
            }
        }
    })
    .unwrap_or(std::ptr::null_mut())
}

/// Write a settings value (§24 settings KV). False on failure.
#[no_mangle]
pub unsafe extern "C" fn cadence_store_setting_set(
    store: *mut StoreHandle,
    key: *const c_char,
    value: *const c_char,
) -> bool {
    if store.is_null() {
        set_last_error("cadence_store_setting_set: store is NULL".into());
        return false;
    }
    guarded("cadence_store_setting_set", || {
        let (Some(k), Some(v)) = (cstr_arg(key), cstr_arg(value)) else {
            set_last_error("key/value is NULL or not UTF-8".into());
            return false;
        };
        let store = &*store;
        match store.store.lock().unwrap().set_setting(&k, &v) {
            Ok(()) => true,
            Err(e) => {
                set_last_error(format!("setting set ({k}): {e}"));
                false
            }
        }
    })
    .unwrap_or(false)
}

/// Store one utterance's retained audio (§24, opt-in). `purge_after_ms` is an absolute
/// epoch-ms deadline; ≤ 0 means no per-blob deadline (the blob lives and dies with its
/// utterance). False on failure.
#[no_mangle]
pub unsafe extern "C" fn cadence_store_audio_put(
    store: *mut StoreHandle,
    id: *const c_char,
    data: *const u8,
    data_len: usize,
    purge_after_ms: i64,
) -> bool {
    if store.is_null() {
        set_last_error("cadence_store_audio_put: store is NULL".into());
        return false;
    }
    guarded("cadence_store_audio_put", || {
        let Some(id) = cstr_arg(id) else {
            set_last_error("id is NULL or not UTF-8".into());
            return false;
        };
        if data.is_null() {
            set_last_error("data is NULL".into());
            return false;
        }
        let bytes = std::slice::from_raw_parts(data, data_len);
        let deadline = (purge_after_ms > 0).then_some(purge_after_ms);
        let store = &*store;
        match store.store.lock().unwrap().put_audio_blob(&id, bytes, deadline) {
            Ok(()) => true,
            Err(e) => {
                set_last_error(format!("audio put ({id}): {e}"));
                false
            }
        }
    })
    .unwrap_or(false)
}

/// Fetch a retained audio blob. Returns a malloc'd buffer (length in `*out_len`) that the
/// caller frees with `cadence_bytes_free`, or NULL when absent / on error (see last_error;
/// absence sets no error).
#[no_mangle]
pub unsafe extern "C" fn cadence_store_audio_get(
    store: *mut StoreHandle,
    id: *const c_char,
    out_len: *mut usize,
) -> *mut u8 {
    if store.is_null() || out_len.is_null() {
        set_last_error("cadence_store_audio_get: store/out_len is NULL".into());
        return std::ptr::null_mut();
    }
    *out_len = 0;
    guarded("cadence_store_audio_get", || {
        let Some(id) = cstr_arg(id) else {
            set_last_error("id is NULL or not UTF-8".into());
            return std::ptr::null_mut();
        };
        let store = &*store;
        match store.store.lock().unwrap().get_audio_blob(&id) {
            Ok(Some(data)) => {
                let mut boxed = data.into_boxed_slice();
                let ptr = boxed.as_mut_ptr();
                *out_len = boxed.len();
                std::mem::forget(boxed);
                ptr
            }
            Ok(None) => std::ptr::null_mut(),
            Err(e) => {
                set_last_error(format!("audio get ({id}): {e}"));
                std::ptr::null_mut()
            }
        }
    })
    .unwrap_or(std::ptr::null_mut())
}

/// Hard-delete one audio blob and clear any utterance reference to it. True if a blob
/// row existed.
#[no_mangle]
pub unsafe extern "C" fn cadence_store_audio_delete(
    store: *mut StoreHandle,
    id: *const c_char,
) -> bool {
    if store.is_null() {
        set_last_error("cadence_store_audio_delete: store is NULL".into());
        return false;
    }
    guarded("cadence_store_audio_delete", || {
        let Some(id) = cstr_arg(id) else {
            set_last_error("id is NULL or not UTF-8".into());
            return false;
        };
        let store = &*store;
        match store.store.lock().unwrap().delete_audio_blob(&id) {
            Ok(existed) => existed,
            Err(e) => {
                set_last_error(format!("audio delete ({id}): {e}"));
                false
            }
        }
    })
    .unwrap_or(false)
}

/// Delete a single utterance (and its audio blob) by id — the dashboard's per-row delete.
/// Returns true if a row was removed.
#[no_mangle]
pub unsafe extern "C" fn cadence_store_delete_utterance(
    store: *mut StoreHandle,
    id: *const c_char,
) -> bool {
    if store.is_null() {
        set_last_error("cadence_store_delete_utterance: store is NULL".into());
        return false;
    }
    guarded("cadence_store_delete_utterance", || {
        let Some(id) = cstr_arg(id) else {
            set_last_error("id is NULL or not UTF-8".into());
            return false;
        };
        let store = &*store;
        match store.store.lock().unwrap().delete_utterance(&id) {
            Ok(existed) => existed,
            Err(e) => {
                set_last_error(format!("delete utterance ({id}): {e}"));
                false
            }
        }
    })
    .unwrap_or(false)
}

/// §24 retention job: purge audio blobs past their `purge_after` deadline. Returns blobs
/// purged, or -1 on failure. The shell runs this at launch next to the utterance purge.
#[no_mangle]
pub unsafe extern "C" fn cadence_store_audio_purge_expired(store: *mut StoreHandle) -> i64 {
    if store.is_null() {
        set_last_error("cadence_store_audio_purge_expired: store is NULL".into());
        return -1;
    }
    guarded("cadence_store_audio_purge_expired", || {
        let store = &*store;
        match store.store.lock().unwrap().purge_expired_audio_blobs() {
            Ok(n) => n as i64,
            Err(e) => {
                set_last_error(format!("audio purge: {e}"));
                -1
            }
        }
    })
    .unwrap_or(-1)
}

/// Free a buffer returned by `cadence_store_audio_get`. `len` must be the value that call
/// wrote to `out_len`.
#[no_mangle]
pub unsafe extern "C" fn cadence_bytes_free(ptr: *mut u8, len: usize) {
    if ptr.is_null() {
        return;
    }
    guarded("cadence_bytes_free", || {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)));
    });
}

/// Free a string returned by this library (currently `cadence_store_recent_json`).
#[no_mangle]
pub unsafe extern "C" fn cadence_string_free(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    guarded("cadence_string_free", || {
        drop(CString::from_raw(s));
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
            Box::new(|| Ok(Box::new(CountingAsr) as _)),
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

    #[test]
    fn idle_unload_reloads_transparently_on_next_dictation() {
        // Tiny idle window so the unload provably fires between dictations. Env is
        // process-global: restore it before the assertions so parallel-test pollution
        // windows stay minimal (other tests here don't idle long enough to unload).
        std::env::set_var("CADENCE_UNLOAD_SECS", "1");
        let h = Harness::new();
        std::env::remove_var("CADENCE_UNLOAD_SECS");

        // Let the idle timeout fire: the worker must drop its engine.
        std::thread::sleep(Duration::from_millis(1500));

        // A full dictation AFTER the unload must work end-to-end (factory reload path).
        unsafe { cadence_engine_trigger_down(h.engine, false) };
        h.expect("start_capture");
        push_chunk(&h, 1600);
        push_chunk(&h, 1600);
        unsafe { cadence_engine_trigger_up(h.engine) };
        h.expect("stop_capture");
        unsafe { cadence_engine_capture_stopped(h.engine) };
        let ins = h.expect("run_insertion");
        assert!(
            ins["text"].as_str().unwrap().starts_with("Hello"),
            "reloaded engine produced wrong text: {}",
            ins["text"]
        );
    }

    #[test]
    fn store_roundtrip_over_c_abi() {
        let mut db = std::env::temp_dir();
        db.push(format!("cadence-ffi-store-{}.db", std::process::id()));
        std::fs::remove_file(&db).ok();
        let db_c = CString::new(db.to_str().unwrap()).unwrap();
        let key = [7u8; 32];

        let store = unsafe { cadence_store_open(db_c.as_ptr(), key.as_ptr(), key.len()) };
        assert!(!store.is_null(), "open failed: {}", last_err());

        let rec = CString::new(
            r#"{"utterance":"utt-1","ts":"2026-07-18T23:00:00Z","app":"Notes","text":"over the c abi","inserted":true,"strategy":"direct","insertion_ms":40,"capture_start_ms":36}"#,
        )
        .unwrap();
        assert!(unsafe { cadence_store_persist_json(store, rec.as_ptr()) }, "{}", last_err());

        let json = unsafe { cadence_store_recent_json(store, 10) };
        assert!(!json.is_null(), "{}", last_err());
        let s = unsafe { CStr::from_ptr(json) }.to_str().unwrap().to_owned();
        unsafe { cadence_string_free(json) };
        let arr: serde_json::Value = serde_json::from_str(&s).unwrap();
        assert_eq!(arr[0]["text"], "over the c abi");
        assert_eq!(arr[0]["capture_start_ms"], 36, "extra metric survived");

        // Settings KV over the ABI (per-app rules ride on this).
        let k = CString::new("disabled_apps").unwrap();
        let v = CString::new(r#"["Terminal"]"#).unwrap();
        assert!(unsafe { cadence_store_setting_set(store, k.as_ptr(), v.as_ptr()) });
        let got = unsafe { cadence_store_setting_get(store, k.as_ptr()) };
        assert!(!got.is_null());
        assert_eq!(unsafe { CStr::from_ptr(got) }.to_str().unwrap(), r#"["Terminal"]"#);
        unsafe { cadence_string_free(got) };
        let missing = CString::new("never-set").unwrap();
        assert!(unsafe { cadence_store_setting_get(store, missing.as_ptr()) }.is_null());

        // Retained audio (§24 opt-in) over the ABI: put → get → linked record → delete.
        let blob_id = CString::new("audio-abi-1").unwrap();
        let wav: &[u8] = &[0x52, 0x49, 0x46, 0x46, 0x00, 0xFF, 0x7F, 0x80];
        assert!(
            unsafe { cadence_store_audio_put(store, blob_id.as_ptr(), wav.as_ptr(), wav.len(), 0) },
            "{}",
            last_err()
        );
        let mut len = 0usize;
        let got_audio = unsafe { cadence_store_audio_get(store, blob_id.as_ptr(), &mut len) };
        assert!(!got_audio.is_null(), "{}", last_err());
        assert_eq!(unsafe { std::slice::from_raw_parts(got_audio, len) }, wav);
        unsafe { cadence_bytes_free(got_audio, len) };

        let rec_audio = CString::new(
            r#"{"utterance":"utt-2","ts":"2026-07-18T23:01:00Z","text":"with audio","audio_blob_id":"audio-abi-1"}"#,
        )
        .unwrap();
        assert!(unsafe { cadence_store_persist_json(store, rec_audio.as_ptr()) }, "{}", last_err());
        let json = unsafe { cadence_store_recent_json(store, 1) };
        let s = unsafe { CStr::from_ptr(json) }.to_str().unwrap().to_owned();
        unsafe { cadence_string_free(json) };
        let arr: serde_json::Value = serde_json::from_str(&s).unwrap();
        assert_eq!(arr[0]["audio_blob_id"], "audio-abi-1");

        assert!(unsafe { cadence_store_audio_delete(store, blob_id.as_ptr()) });
        let mut len2 = 0usize;
        assert!(unsafe { cadence_store_audio_get(store, blob_id.as_ptr(), &mut len2) }.is_null());
        assert_eq!(unsafe { cadence_store_audio_purge_expired(store) }, 0);

        // Wrong key fails closed with a diagnostic, not a crash.
        unsafe { cadence_store_free(store) };
        let wrong = [8u8; 32];
        let bad = unsafe { cadence_store_open(db_c.as_ptr(), wrong.as_ptr(), wrong.len()) };
        assert!(bad.is_null());
        assert!(last_err().contains("store open"), "unexpected: {}", last_err());

        std::fs::remove_file(&db).ok();
    }

    fn last_err() -> String {
        let p = cadence_last_error();
        if p.is_null() {
            return String::new();
        }
        unsafe { CStr::from_ptr(p) }.to_str().unwrap_or("").to_owned()
    }
}
