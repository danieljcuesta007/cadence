//! cadence-orchestrator — the shared state machine driving both native shells (§16.2, §26).

pub mod machine;
pub mod partial;
pub mod pipeline;
pub mod ring;

pub use machine::Orchestrator;
pub use partial::{PartialScheduler, DEFAULT_TAIL_WINDOW_SAMPLES, PARTIAL_AUDIO_CTX_FRAMES};
pub use pipeline::{CollectSink, InsertionSink, Pipeline, RunReport, Timings};
pub use ring::RingBuffer;
