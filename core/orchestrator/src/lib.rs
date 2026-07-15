//! cadence-orchestrator — the shared state machine driving both native shells (§16.2, §26).

pub mod machine;
pub mod pipeline;
pub mod ring;

pub use machine::Orchestrator;
pub use pipeline::{CollectSink, InsertionSink, Pipeline, RunReport, Timings};
pub use ring::RingBuffer;
