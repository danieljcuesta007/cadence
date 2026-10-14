# Cadence

Local-first, cloud-optional, system-wide AI voice dictation for macOS.

Hold Right-Option, speak, release — the text lands in whatever field has focus. Transcription
runs entirely on-device (Whisper via Metal); nothing leaves the machine, and the app contains no
networking code. Hold Left-Option instead and it dictates in your second
language, at the same speed.

**Status:** Phase 1, in daily use on Apple Silicon. `platform-windows/` and `cloud/` are
reserved by the blueprint and currently empty.

**Single source of truth:** [`docs/CADENCE_BLUEPRINT.md`](docs/CADENCE_BLUEPRINT.md) (PRD + TDD +
UX spec + roadmap). Progress: [`docs/STATUS.md`](docs/STATUS.md) · Decisions:
[`docs/DECISIONS.md`](docs/DECISIONS.md) · ADRs: [`docs/adr/`](docs/adr/)

## What it does

- **Push-to-talk dictation** into any app — direct Accessibility insertion where the target
  allows it, clipboard paste with restore where it doesn't, and a verified readback either way
  so it never claims success for text that did not land.
- **Two-pass ASR** — a fast partial appears in the overlay while you speak; a refined pass
  produces the text that gets inserted.
- **Bilingual on two keys** — Right-Option dictates in one language, Left-Option in the
  other, each pinned. Switching languages costs a different finger rather than a menu trip or
  the ~160 ms that auto-detection adds to every utterance. Either key can be set to Automatic
  if you prefer detection, and the second key can be unbound entirely.
- **Cleanup you can predict** — fillers ("um", and "you know" / "I mean" when set off by
  commas) and stutters ("the the") are removed; "no no" and "had had" are not. Say "scratch
  that" or "delete that" as its own phrase to drop the clause before it. Every removal is
  logged by count only, and the raw transcript stays in history.
- **Personal dictionary** for proper nouns, applied to the refined pass as a Whisper prompt.
- **Encrypted history** in SQLCipher, with an optional retained-audio mode (off by default) and
  a retention window you choose.
- **Dashboard** — time saved, words dictated, speaking pace, streak, per-day activity, and
  where you dictate, plus a searchable transcript history with copy, re-insert, and delete.
- **Light and dark** — follows macOS by default; pin Light or Dark from the menu (Appearance)
  or the switch in the dashboard header. The choice is kept in the encrypted settings.
- **Undo** the last insertion with Control-Option-Command-Z. Holding a modifier chord never
  starts a dictation, so the undo shortcut cannot trip the push-to-talk keys.
- **Verbatim mode** (menu, or Control-Option-Command-V anywhere) inserts exactly what was
  heard, with no cleanup — for paths, flags, commands and code. It stays on until you turn it
  off, and the setting is kept in the encrypted store.

## Install

From the first release (v0.1.0) on, download `Cadence.dmg` from [the latest release](https://github.com/danieljcuesta007/cadence/releases/latest)
or the site, https://cadence-dictation.pages.dev, or use Homebrew:

```sh
brew tap danieljcuesta007/cadence https://github.com/danieljcuesta007/cadence
brew install --cask cadence
```

Cadence isn't notarized by Apple (that costs $99 a year, and Cadence is free), so the first
open needs **System Settings › Privacy & Security › Open Anyway**. Releases:
`qa/package-app.sh && qa/make-dmg.sh <version>` (it refuses a wrong model, missing licenses
or a broken signature, and fills in the checksum for the cask and site).

## Requirements (to build it yourself)

No Homebrew or admin rights needed. Everything below is user-local.

| Requirement | Notes |
| --- | --- |
| Apple Silicon Mac | Whisper runs on Metal; Intel is untested |
| Rust (1.97+, edition 2021) | `rustup` installs user-local; the build sources `~/.cargo/env` |
| Swift toolchain (6.2+) | Command Line Tools are enough: `xcode-select --install`. No Xcode, no XCTest |
| CMake (3.31+) | Needed to build vendored whisper.cpp. Not in this repo — see below |
| `curl`, `shasum`, `python3` | Preinstalled on macOS; `python3` is only used by the WER harness |

**CMake** is the one dependency a fresh clone does not get for free: `tools/cmake-local/` is
gitignored. Either point the build at any CMake you already have —

```sh
export CMAKE=$(command -v cmake)
```

— or download the official macOS universal build and unpack it to
`tools/cmake-local/cmake-<version>-macos-universal/`, which is the path `qa/build-shell.sh`
defaults to.

## Getting a model

Model weights are gitignored and fetched on demand, with SHA-256 pins verified after download:

```sh
models/fetch-models.sh          # ~700 MB total across tiers
```

The app bundles `ggml-small.bin` (multilingual). `ggml-base.en.bin` is kept as the golden
rollback and as the baseline the accuracy harness compares against.

## Building

```sh
qa/build-shell.sh               # Rust core (staticlib, whisper + Metal), then the Swift shell
qa/setup-signing.sh             # once: creates a stable self-signed identity in its own keychain
qa/package-app.sh --install     # builds Cadence.app and installs to ~/Applications
```

Signing matters more than it looks: macOS ties Accessibility and Microphone grants to the code
signature, so an ad-hoc signature makes every rebuild silently lose its Accessibility permission
(the toggle keeps showing as ON). `setup-signing.sh` produces a stable identity so grants survive
rebuilds.

On first launch, grant **Microphone** and **Accessibility** (and **Input Monitoring** if
prompted). The app is an agent — it has no Dock window; its home is the menu-bar mic icon.
Clicking the Dock tile or reopening the app opens the dashboard.

## Where your data lives

| Path | Contents |
| --- | --- |
| `~/.cadence/store.db` | Encrypted history (SQLCipher), plus optional retained audio |
| `~/.cadence/logs/cadence.log` | Diagnostics, trimmed at 2 MB |
| login keychain, `dev.cadence.app/store-key` | The 32-byte database key, non-syncing |
| `~/.cadence/store.key` | A second copy of that key (0600), so a replaced keychain can't lock you out |
| `~/.cadence/store.locked-*.db` | A store no key could open, kept (never deleted) in case its key turns up |
| `~/.cadence/recovered.json` | Per-day counts rebuilt from the log by `tools/recover_from_log.py` |

The key exists in two places because macOS can replace the login keychain (it did on
11 Oct 2026, and a keychain-only key took months of history with it). Losing *both* copies
still makes the history unreadable, so back up `~/.cadence` (Time Machine does).
Disk-level protection is FileVault's job.

## Tests

```sh
cargo test --workspace                             # core: orchestrator, cleanup, store, models, ffi
cargo test -p cadence-asr --features whisper       # ASR against real model files
platform-macos/.build/release/insertctl selftest   # insertion + readback logic
platform-macos/.build/release/cadence selftest-stats     # dashboard metric maths
platform-macos/.build/release/cadence selftest-store     # store key: keep, rescue, or reset
python3 -m unittest discover -s tools -p 'test_*.py'      # log recovery (tools/recover_from_log.py)
platform-macos/.build/release/cadence selftest-hotkeys   # two-key PTT arbitration + app chords
platform-macos/.build/release/cadence selftest-lifecycle # startup, heartbeat, shutdown evidence
platform-macos/.build/release/cadence selftest-appearance [--out dir]  # light/dark renders
qa/wer-harness.sh                                  # word error rate + ASR latency together
qa/spine-selftest.sh                               # end-to-end WAV to inserted text
(cd site && npm run build && npm test)             # website: links, CSP, honesty, checksums
python3 -B -m unittest qa.test_make_dmg            # release disk image guards
```

Is Start at Login really registered? Ask the installed bundle, not the menu checkmark
(`sfltool dumpbtm` needs an admin password): `~/Applications/Cadence.app/Contents/MacOS/Cadence login-item`.

### When dictation stops working

Run `~/Applications/Cadence.app/Contents/MacOS/Cadence doctor` (use `/Applications` if
installed there). It prints a read-only JSON report with running processes, recorded engine
and hotkey readiness, microphone/Accessibility status, Start at Login, bundled-model
availability, and suggested recovery steps. Exit 0 means the checks passed; exit 1 means
something needs attention. Permission checks describe the diagnostic executable, so run
the installed bundle rather than a bare development binary. No permission prompts appear.

If the app is stopped, `open ~/Applications/Cadence.app` starts it again. Start at Login
launches it when you log in; it does not restart it after every quit or termination.

The menu's **Open Diagnostic Logs…** opens `~/.cadence/logs`. `lifecycle.json` keeps the
current and previous session: startup time, PID, version, a heartbeat every 60 seconds,
readiness, and a shutdown reason when available. Launch and exit events also go into
`cadence.log`, with queued logs flushed at shutdown. Normal menu quits, application quits,
system shutdown requests, and known startup failures are recorded. A missing shutdown
record is reported as unexplained; it cannot distinguish crashes, force quits, SIGKILL,
or power loss. Boot-session changes identify an intervening reboot. Sleep can delay a
heartbeat, so an old heartbeat alone is not evidence of a hang.

Lifecycle records contain no transcripts, audio, or encryption keys. `doctor` reads only
these records and crash-report metadata, and does not read the history store or raw log
contents. Older `cadence.log` entries can contain personal data from earlier versions;
review them locally before sharing. Malformed or newer-format lifecycle records are
preserved and diagnosed; logging failures never prevent dictation.

The Swift layer has no XCTest (Command Line Tools do not ship it), so pure logic is covered by
the two `selftest` subcommands above instead.

## Measured behaviour

Numbers from the harness and from real-use logs, not estimates. See `docs/STATUS.md` for method.

| Metric | Value |
| --- | --- |
| Word error rate (bundled `small.bin`, 15 fixtures) | 1.78% |
| Refined ASR pass | ~500 ms |
| End-to-end, speech end to inserted text | ~600 ms |
| Capture start | 43 ms median, 79 ms p90 |
| Idle memory, after the 5-minute model unload | ~36 MB |

## Known trade-offs

- **Automatic language detection costs about 160 ms per dictation** and is meaningfully less
  accurate for Spanish than pinning it (21.5% versus 13.6% WER on synthesized fixtures). This
  is why the default binds each key to a pinned language instead: you keep bilingual dictation
  without paying detection on either. Automatic remains available per key.
- The refined pass at ~500 ms means end-to-end sits above the blueprint's 700 ms target once
  insertion is included. Recorded as a miss rather than quietly restated.
- Accuracy fixtures are synthesized with `say`, not human speech, so absolute WER is optimistic;
  it is reliable for comparing two builds, which is what it is used for.

## Non-negotiable gates

1. Never lose a user's words. 2. Never freeze or corrupt the target app (zero freezes and zero
clipboard corruption is a release blocker). 3. Fully offline baseline. 4. Legible privacy
(per-utterance badge, zero retention by default, no screenshots). 5. Idle under 150 MB RAM,
under 1% CPU, zero network. 6. Flagship onboarding, under 60 seconds to first dictation.

## Repo layout (blueprint §25)

```
core/               shared Rust core (orchestrator, asr, cleanup, store, models, ipc)
platform-macos/     Swift/AppKit shell (capture, hotkeys, overlay, insertion, dashboard)
platform-windows/   reserved — empty
cloud/              reserved — empty
models/             fetch + eval pipelines and pinned hashes
shared-protocol/    API + IPC schema
qa/                 harnesses: insertion matrix, soak, latency, WER
docs/               blueprint, ADRs, status, decisions
tools/              headless CLI and local toolchain helpers
```

## License

MIT — see [LICENSE](LICENSE). Note that the vendored dependencies carry their own terms that
continue to apply to any built artifact: whisper.cpp and ggml (MIT), SQLCipher (BSD-style),
OpenSSL (Apache-2.0). Model weights are downloaded from their publishers under their own terms
and are not redistributed here.
