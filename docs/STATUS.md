# STATUS — Cadence build progress

Updated: 2026-07-25 · Phase: **1 (MVP spine)** · Blueprint: docs/CADENCE_BLUEPRINT.md

## Systems audit (2026-07-25) — measured, not reviewed

Nine days of real single-user use (49 captures, 40 insertions, `~/.cadence/logs/cadence.log`),
plus a WER re-run and a live AX readback. Three things were wrong; two of them are now fixed.

**1. 35 % of insertions falsely reported failure — FIXED.** 14 of 40 live insertions logged
`clipboard_notify inserted=false verify=contradicted`. Root cause was not timing: the AC-20
readback built `probe = text.suffix(64)` and asked `value.contains(probe)`, an exact substring
match against text the target had already **re-flowed**. Measured with `insertctl read` against a
live Claude Code terminal: Terminal exposes `AXTextArea` = the *visible screen only*, 1 870 chars
over 87 lines wrapped at ~93 columns, continuation lines carrying a `│ ` gutter. A contiguous
64-char probe survives that roughly one time in four — matching the observed hit rate (7/25:
12:50 contradicted, 13:03 contradicted, 13:13 verified). The 0.18 s re-read added 2026-07-19
could never help, because nothing was late.
Four consequences, all silent: the user was told "saved to clipboard" for text that had landed
(double-paste risk); the clipboard was deliberately left stomped (`clipboardRestored=false` is
correct *given* a contradiction); undo was never armed (the core arms only on confirmed
insertion); dashboard time-saved undercounted by ~35 %.
Fix: `foldForReadback` reduces both sides to letters+digits, lowercased, before comparing —
surviving soft wrap, gutters, padding and smart-quote substitution (this machine has smart
quotes on), while a genuine swallow (the Pages page-layout case this check exists for) is still
absent under any folding. Applied to **both** readback sites; `directInsert`'s exact match had
the same flaw, where a false negative is worse — it falls through to paste and the text lands
twice. Pinned by 4 new checks in `insertctl selftest` (9/9), one of which asserts the *old*
exact probe fails on the measured wrapped input. Contradictions now log app + char count +
detail, so the next bad verdict is diagnosable without decrypting history.

**2. The bundled model's accuracy was unmeasured — now measured, and it is the best we have.**
`ggml-small.bin` (multilingual, 488 MB) ships, but §30 had only ever scored `base.en` and
`small.en`. Re-run over the same 15 fixtures / 225 reference words:

| model | WER | mean ASR | max ASR |
|---|---|---|---|
| **ggml-small.bin (bundled)** | **1.778 %** (4/225) | 672 ms | 798 ms |
| ggml-small.en.bin | 3.111 % (7/225) | 639 ms | 769 ms |
| ggml-base.en.bin | 5.778 % (13/225) | 215 ms | 273 ms |

Both previously-recorded numbers reproduced exactly, so the harness is trustworthy. English
accuracy **improved** 1.3 points when bilingual auto-detect landed — the prior assumption that
multilingual would cost English accuracy was wrong. The real cost is latency: the refined pass is
now ~670 ms, so end-to-end (ASR + insertion ≈ 250 ms) exceeds the §28 ≤700 ms p50 budget.
Deliberate trade (accuracy is the daily-use bottleneck) but it should be recorded as a miss, not
as "met". Still open: fixtures are TTS-synthesized (no real-human/accented set), **no Spanish
fixtures at all** despite shipping Spanish, and neither the personal dictionary nor `language=auto`
is covered by the harness.

**3. Test coverage is lopsided where change is fastest — partially addressed.** 6 313 LOC Rust
carries 92 tests; 4 406 LOC Swift (2 892 in the app layer) carries none, because this machine has
Command Line Tools only — no XCTest. That is where every feature of the last two weeks lives.
Interim pattern established here rather than left as a wish: pure logic is exercised through
`insertctl selftest` (now 9 checks), which needs no test target. Still untested: Stats maths
(time-saved, streak, wpm), dashboard filtering, dictionary dedupe.

**Directory-shaped, empty:** `core/dictionary/`, `core/redaction/`, `platform-windows/`, `cloud/`.
The store carries a `redacted` column nothing ever sets true, so "redacted utterances never
retain audio" is a guard that cannot fire — the schema implies a privacy story the code does not
have yet. Local small-LLM cleanup is still the rule engine (ADR-0002).

**Closed by evidence:** the 2026-07-19 route-change capture fix held — 6 lost utterances that
day (`tap install rejected … sampleRate`), **zero since**. Capture start p50 43 ms / p90 79 ms
(§28 ≤50 ms perceived: p50 met), one 330 ms outlier, likely the post-idle-unload reload. No
Cadence crash reports on the machine. AirPods plug/unplug during idle remains the one
never-live-tested recovery path.

## Shipped 2026-07-24 → 25 (five merges)

- **Dashboard v3, native** (`fe77e8f`): value-first layout — time-saved hero, activity chart,
  top apps, streak, wpm; engine latency demoted to a footer. Stats computed Swift-side from
  utterance rows; no aggregation in the core. Brand moved muted-sage → richer green `#3F8A4F`
  (`BrandColor.swift`, icon + overlay regenerated).
- **Runtime language toggle + dashboard v2** (`5cbf29b`): bilingual auto-detect on the
  multilingual model, Language menu (Automatic/English/Spanish), per-decode — no model reload.
- **Personal dictionary** (`b95367b`): terms bias the whisper `initial_prompt`; menu editor.
  "Adesuna" → "Addisuna" verified live.
- **Per-utterance delete + real Re-insert** (`7eb6b7e`): `lastActiveApp` tracking so a past
  dictation can be placed back into the app the user came from.
- **Both ASR passes + add-to-dictionary + focus-aware Re-insert** (`af7e88c`):
  `transcript_instant` was a §24 column nothing ever wrote and the refined pre-cleanup text never
  left the core — `PersistUtterance` now carries `transcript_final`, the router records the last
  streaming partial, both land in their own columns (not `extra_json`), and the dashboard shows
  each pass only when it differs from what was inserted (compared on words, so cleanup's
  punctuation is not reported as disagreement). Selecting text in a transcript adds it to the
  dictionary (button + contextual menu, ≤4 words, case-insensitive dedupe; an open editor absorbs
  the term so Save cannot overwrite it). Re-insert waits for the target to actually own focus
  (poll + 1.5 s deadline → clipboard fallback naming the app) instead of guessing at 0.35 s.
  Also: per-utterance metrics are cleared at capture start — a cancelled utterance never reaches
  persist, so its numbers, and now its partial transcript, rode along on the next record.

**Live checks still owed by the user:** dictionary accuracy with real voice; Re-insert timing and
target; per-utterance delete; and after this batch, whether `verify=contradicted` disappears from
the log during normal terminal dictation (the single number that says finding 1 is closed).

## Resource soak + stall hunt (2026-07-18)

**Idle soak found a real crash.** The resident app had idled 8 h 42 m (natural soak: avg CPU
≈0.008 %, 0 sockets, phys footprint 176–218 MB — CMPRS shows nearly all of it is the
OS-compressed whisper model; RSS settles ~25 MB). Then, ~20 min after a successful live
dictation, the app **aborted on an audio route change**: `AVAudioEngineConfigurationChange` →
observer (on the posting thread, un-debounced) → `teardownTap`+`prewarm` → `installTapOnNode`
raised an ObjC `NSException` mid-reconfiguration → uncatchable in Swift → SIGABRT
(`Cadence-2026-07-18-200950.ips`). Fix (same day):
- `CObjCCatch` target: `CadenceCatchNSException` fences the install; a raise now degrades to
  `CaptureError.tapInstall` (prewarm swallows it; next `start()` rebuilds cold — that
  recovery path already existed). Fence unit-proven (raise caught, clean path nil).
- Route-change rebuild now debounced 150 ms onto the main queue (changes burst on arbitrary
  threads; re-tapping while the engine reconfigures is what raised).
- `ensureTap` also guards `channelCount > 0` (transitional formats can be 48 kHz / 0 ch).
- Not yet re-proven against a real route change — plug/unplug AirPods while idle to confirm.

**Stuck "idle local" pill (user-reported 2026-07-18, screenshot):** core emits
`show_overlay {state: idle}` on return-to-rest paths (cancel, re-enable, error recovery);
the router rendered it as a pill with literal "idle" text and never faded it. Fixed both
layers: router maps idle → immediate fade; `OverlayHUD.show` treats "idle" as dismiss
(belt-and-braces). Needs a live dictation + Esc-cancel to confirm.

**Build-system trap (2026-07-18, found live):** SwiftPM does not track the external
`libcadence_ffi.a` — a rebuilt core with unchanged Swift sources did NOT relink, and
`package-app.sh` shipped a 26-minute-old binary as if new. `build-shell.sh` now deletes the
shell binary when the staticlib is newer, forcing the link. If a core change ever seems to
"not take", check `ls -l target/release/libcadence_ffi.a platform-macos/.build/release/cadence`.

**App identity (2026-07-18):** designed app icon — warm ivory squircle (true Apple
continuous-corner via CALayer `cornerCurve`), five-bar cadence mark in warm ink, gold peak
bar. Source `platform-macos/App/AppIcon/render-icon.swift` (CoreAnimation → 1024 PNG),
`make-icns.sh` → `AppIcon.icns`; package-app.sh bundles it (`CFBundleIconFile`). App pinned
to the Dock (persistent-apps; app stays LSUIElement — Dock tile is a launcher, no running
entry, menu-bar-agent design unchanged). Verified: NSWorkspace resolves the custom icon.

**Metal stall hunt: 10/10 clean.** ~380 headless whisper+Metal decodes (stream_spike partials
×3 audio_ctx + refined, 120 s watchdog, launched non-foreground): zero stalls, refined decode
~113 ms. The one-off 30 s stall did not reproduce headlessly; App Nap on the .app process
remains prime suspect and the activity-assertion mitigation stands.

**Budget verdict (§28 idle):** CPU <1 % PASS (≈0.008 %), network 0 PASS, RAM <150 MB **MISS
by ~26–68 MB**, entirely the resident model (compressed while idle). Confirms the idle
model-unload lever (ADR-0006) is what closes it. Sampler: `qa/soak.sh` →
`qa/soak-results.jsonl` (30 s interval; footprint/CMPRS/RSS/cputime/threads/sockets).

## Phase-0 exit criteria (closed 2026-07-14, except the deferred Windows gate)

| Criterion (§32) | Status |
|---|---|
| Headless core transcribes WAV → cleaned text | ✅ 144 ms warm / 553 ms cold, 282 MB peak (M4, base.en, Metal) |
| Insertion prototype, 0 freezes / 0 corruption | ✅ automated 9/9, 0 freezes, 0 corruption (full table: `qa/matrix-results.jsonl` + git history of this file). Interactive pass 2026-07-16: Spotlight, Pages, Word, VS Code, Messages + Slack (both draft-to-self, never sent, drafts cleared) — 6/6 PASS. Still uncovered: not-installed apps (iTerm2, Cursor, Discord, JetBrains) |
| Windows insertion spike | 🔴 Deferred — no Windows env (ADR-0004); first task when one exists |
| Orchestrator + IPC schema, headless, fully tested | ✅ |
| Golden local model chosen + verified fetch | 🟡 base.en measured via §30 harness: **7.1 % WER, 146.8 ms mean / 206 ms max ASR** (16 TTS fixtures, 225 ref words). Working candidate confirmed by data; final lock still wants a small.en A/B on the same fixtures |

## Phase-1 spine — what works today (2026-07-15)

**Live end-to-end path built:** menu-bar shell (`cadence run`) → Right-Option PTT (CGEvent
tap) → AVAudioEngine capture → FFI ring buffer → whisper.cpp (Metal, worker thread) → rule
cleanup + hallucination guard → real insertion cascade → history JSONL. All driven by the
Phase-0 orchestrator over the new C ABI (ADR-0005).

- **`core/ffi`** (`cadence-ffi`): C ABI + JSON ipc effects; compute effects interpreted
  in-core on core threads; no-lost-words drain contract (`capture_stopped` + 500 ms grace);
  panic-fenced externs. Workspace tests: **50/50** (6 FFI incl. an AC-5 regression test).
- **Swift shell** (`platform-macos`): `CCadenceFFI` (header symlinked from core),
  `CadenceCapture` (16 kHz mono i16 + RMS level), `CadenceHotkeys` (PTT/Esc tap, self-healing),
  `CadenceOverlay` (non-activating NSPanel pill: state glyph, level bars, local chip),
  `cadence` executable (menu-bar agent + effect router + WAV selftest). Build:
  `qa/build-shell.sh`.
- **E2E verification** (`qa/spine-selftest.sh`, run 3× green): WAV injected through the real
  FFI audio path → whisper → cleanup → **direct AX insertion into TextEdit**, readback
  verified, clipboard sentinel restored. **Pipeline 203–233 ms** (3.5 s utterance, model load
  ~180 ms warm), insertion 26–29 ms.
- **Safety, structural:** selftest cannot insert without a frontmost-app guard (default
  TextEdit); the Phase-0 "pasted into WhatsApp" class is closed for all automated runs.

### Fixed this session
- **AC-5 regression (found live):** ring cleared on `StartCapture` raced instant-start audio —
  first 8 000 of 56 235 samples lost, mangling leading words. Clear now happens synchronously
  in `trigger_down` on the caller thread; regression test pins the full window.
- **Overlay level bars invisible (found on first live run):** core emitted `update_waveform`
  correctly (36/utterance, verified via `CADENCE_DEBUG=1` selftest) but the pill's fixed
  260 pt width over-constrained the stack once the bars appeared — AppKit clipped the level
  label. Pill now sizes to content; level label holds a constant 10-glyph width while
  listening so per-chunk updates never relayout.
- **`show_partial` was a stub in the shell router** (previous STATUS claim "shell already
  routes show_partial" was wrong — it parsed but dropped it). Now rendered: instant-pass text
  shows in the pill, head-truncated, and stays up through "thinking" while the refined pass runs.
- **Emoji purge (design rule: no emojis, professional/clean):** overlay glyphs are now
  typographic marks, chip is plain "local"/"cloud", menu-bar icon uses template SF Symbols
  (`mic`/`mic.fill`/…) instead of 🎙/🔴.

### First live mic run (2026-07-15) — PASSED
- Mic TCC granted; 4 dictations, ~90 % word accuracy (user-reported), no freezes.
- Capture start 79–153 ms (85–94 ms warm) — **misses the ≤50 ms perceived target**; needs a
  look (engine pre-warm / keep AVAudioEngine hot between utterances?).
- Insertion live: direct 115 ms once, paste_restore 254–270 ms otherwise (targets non-TextEdit
  apps → cascade fell back as designed); clipboard restored every time.
- Overlay bars/partials were NOT visible on this run — root-caused and fixed above; re-test pending.

## What's stubbed / not started

Superseded in large part — the streaming pass, store, undo, per-app rules, model registry, idle
unload and dictionary all shipped (see the dated sections below and the 7/24–25 list above).
Accurate as of 2026-07-25:

- **Empty directories, no code:** `core/dictionary/` (the shipped dictionary is a whisper-prompt
  bias in the shell, not a crate), `core/redaction/`, `platform-windows/`, `cloud/`.
- **Redaction:** unimplemented; the `redacted` column is never set true.
- **Local small-LLM cleanup:** rule engine still standing in (ADR-0002).
- **Settings UI / onboarding:** everything lives in the menu bar (retention, audio, language,
  dictionary). Adequate for one user; a real Settings window is the gap before a second one.
- **Caret-anchored overlay**, asymmetric model-signature verify (needs a signing key), full
  registry-resolve over FFI, §24 corrections/style/sync tables.
- **Windows everything, cloud everything** (ADR-0004: no Windows environment).

## Current metrics vs targets (§28)

Refreshed 2026-07-25 from 9 days of live logs + the §30 harness on the **bundled** model.

| Metric | Target | Measured |
|---|---|---|
| Local refined-pass pipeline | ≤ 700 ms p50 | **MISS by design** — ASR alone 672 ms mean / 798 ms max on bundled `ggml-small.bin` (§30, 15 fixtures); + ~250 ms insertion ≈ 0.9 s end-to-end. Was 203–233 ms on base.en; accuracy was chosen over latency (1.78 % vs 5.78 % WER) |
| ASR accuracy (§30) | — | **1.778 % WER** bundled multilingual small · 3.111 % small.en · 5.778 % base.en (225 ref words, TTS fixtures) |
| Insertion engine call | ≤ 250 ms + fallback | 26–29 ms direct AX; **253–268 ms paste_restore live** (the real daily path — includes the 250 ms paste settle + readback) |
| Insertion outcome (live, 40 real) | inserted, verified | 24 verified · 2 unverifiable · **14 falsely contradicted → root-caused and fixed 7/25** |
| Key-down → capture start | ≤ 50 ms perceived | **p50 43 ms / p90 79 ms / max 330 ms** over 49 live captures — p50 target MET; the tail is likely post-idle-unload reload |
| Active RAM peak | < 1.2 GB | 282 MB (Phase-0 headless, base.en; shell with small.bin unmeasured) |
| Idle RAM / CPU / network | <150 MB / <1% / 0 | **36 MB after unload** (was 177 MB) / ≈0.008 % / 0 sockets — all three MET (`qa/unload-verify.jsonl`) |
| Stability | no crashes | 0 Cadence crash reports on the machine; 6 lost utterances 7/19 (route change), 0 since |

## Open risks (watchlist)
1. **Windows spike unproven** (ADR-0004).
2. **Streaming/instant pass** — DONE for push-to-talk (shared `PartialScheduler`, warmup,
   FFI real-whisper test green, ADR-0006). **Sliding tail window DONE 2026-07-18:** partials
   now decode only the most recent 8 s (`DEFAULT_TAIL_WINDOW_SAMPLES`, `window_start()` in
   both interpreters), and the FFI engine caps the fast-path encoder to match
   (`PARTIAL_AUDIO_CTX_FRAMES` = 512 ≈ 10.2 s coverage). Measured motivation (stream_spike,
   31.6 s WAV): the old growing window collapsed at ~10 s — the capped encoder saw truncated
   mel and produced garbage ("Hello Hello This ThisN also this") at 1.5–2.7 s/partial; the
   pill would have shown nonsense while costs ballooned. With the tail, each partial is
   ≤ 8 s of audio (~100–125 ms observed at that size). Pinned by
   `long_dictation_partials_decode_only_the_tail` (30 s utterance: every partial ≤ tail cap,
   early windows untruncated, refined pass still sees the full utterance exactly once).
   Context carry across the tail boundary deliberately NOT added: partials are display-only
   and head-truncated in the pill; the refined pass is authoritative (§12.3).
3. **One-off 30 s whisper Metal stall** in a backgrounded selftest (1 of ~6 runs, never
   reproduced). Model loaded fine; the *decode* (audio→text) never returned, and the Metal
   crash fired during process-exit cleanup — confirming a decode was still in flight, not a
   load/init fault. Suspected App Nap (run launched from a script with Terminal backgrounded).
   Mitigation in place: ProcessInfo activity assertion during dictation (disables App Nap for
   the dictation window) — plausibly mitigated, NOT confirmed fixed. Containment: not
   word-losing — audio stays in the ring/history path and a hung utterance does not crash the
   hotkey listener. First suspect if any dictation hangs in "thinking". Watch during soak.
4. Direct-AX coverage across Electron/web apps still shallow (falls back to pasteRestore).
5. WER harness (§30) SHIPPED (2026-07-19, `qa/wer.py` + `wer-harness.sh` + `wer-fixtures.sh`,
   results pinned in `qa/wer-results.json`): alignment-based WER/sub/del/ins scoring +
   per-fixture ASR latency, over 15 held-out fixtures (225 ref words). **Re-run 2026-07-25 across
   all three candidates including the bundled model** — see the metrics table; both prior numbers
   reproduced exactly. Remaining caveats: fixtures are **TTS-synthesized** (no real-human or
   accented set), there are **no Spanish fixtures** despite shipping Spanish, and neither the
   personal dictionary nor `language=auto` is covered. Fixture WAVs gitignored; `manifest.tsv`
   ground truth committed.
6. **Latency budget now exceeded by model choice** (§28 ≤700 ms p50): the bundled multilingual
   small decodes in ~670 ms, so "thinking" is ~0.7–0.9 s. Accepted trade for 1.78 % WER. Levers
   if it ever feels slow: `small.en` for English-only users (≈ same latency, worse WER — not a
   lever), `base.en` (3× faster, 3× the errors), or a smaller `audio_ctx` on the refined pass.
7. **Swift layer has no automated tests** (4 406 LOC; no XCTest on this machine). Pure logic is
   reachable via `insertctl selftest`; Stats maths and dashboard filtering remain unpinned.

## Next steps (§32 order)
1. ~~First live `cadence run`~~ ✅ DONE 2026-07-15 (mic granted, ~90 % accuracy). Overlay
   bars+partials fix CONFIRMED live 2026-07-16. ~~Interactive matrix~~ ✅ DONE 2026-07-16
   (agent-driven, idle-gated, focus-guarded): Spotlight, Pages, Word, VS Code, Messages
   + Slack (both draft-to-self, never sent, drafts cleared) — 6/6 PASS, pasteRestore
   297–343 ms, 0 freezes, 0 clipboard corruption, undo verified in Pages/Word/VS Code.
   Slack: deep link to own-user DM + window-title allowlist before pasting. Findings:
   - **Blind-paste gap (release-gate relevant, §30/AC-20):** in Pages with page-layout focus
     (Book template), pasteRestore returned `inserted: true` but the text landed nowhere.
     The engine cannot distinguish "pasted into a text field" from "paste swallowed". Consider
     post-insert verification (AX readback where possible) before reporting success / arming undo.
   - AX-opaque surfaces are common: Spotlight panel, Pages body/template-chooser/save-sheet,
     VS Code editor (role None) — direct AX impossible there; cascade correctly fell back.
   - Spotlight: systemwide AX focus stays on the previous app while the panel is key, so
     insertion works only because synthetic ⌘V routes to the key window.
   - Electron cold start: first paste into a just-launched VS Code fired before the editor had
     keyboard focus (buffer preserved it via hot exit, but timing matters for real dictation).
   - This machine has ⌘Space disabled (symbolic hotkey 64 off) — Spotlight was opened via a
     CGEvent click on the menu-bar icon.
   Resource soak numbers still unmeasured.
1b. **Cadence.app shipped (2026-07-16, e843c18):** real menu-bar app at `~/Applications/Cadence.app`
   (built by `qa/package-app.sh --install`): LSUIElement agent, bundled model (resolution:
   env → bundle → dev path), ad-hoc signed, Accessibility onboarding (prompt + poll, no
   fatalError), mic usage string. New TCC identity ⇒ user must re-grant mic + Accessibility
   to "Cadence" on first launch. Warm capture path landed same commit: tap+converter built
   once (rebuilt on route change), prepare() re-armed after stop, prewarm() at launch —
   expected to cut the 85–94 ms capture start toward ≤50 ms; **needs live re-measure**.
   Engine still fully stops between utterances (mic indicator = actual listening); if still
   over target, next lever is engine.pause() (verify orange dot goes off first).
1c. **Dashboard + observability (2026-07-16, 7424305 + 9ee75dd):** menu → "History &
   Metrics…" — KPI tiles (dictations, words, avg capture start, avg insertion) + history
   table; history.jsonl enriched per utterance (capture_start_ms, capture_window_ms,
   insertion_ms, strategy, frontmost app). Diagnostics tee to `~/.cadence/logs/cadence.log`
   (the .app's stderr is unobservable). **Ad-hoc TCC trap, hit live:** each rebuild's new
   cdhash silently stales the Accessibility grant while the Settings toggle still shows ON —
   toggling does NOT rebind; only `tccutil reset` + fresh grant does. SOLVED (35c1d31):
   `qa/setup-signing.sh` creates the self-signed "Cadence Dev Signing" identity (dedicated
   pre-authorized keychain, user-domain codeSign trust); package-app.sh signs with it, DR =
   identifier + certificate leaf. **Verified live: grants survived a rebuild+reinstall with
   zero re-prompts (2026-07-16 09:51).**
2. ~~Streaming instant-pass ASR spike + wire into live loop~~ ✅ DONE (ADR-0006; shared
   `PartialScheduler`, warmup, FFI real-whisper test green). Shell now renders `show_partial`
   in the pill (was a stub until 2026-07-15). Follow-on: sliding/chunked window with context
   carry for long dictations.
3. Model registry + integrity ✅ DONE (`core/models`: dependency-free SHA-256 + `ModelRegistry`
   verify/golden-rollback §17.5/§29; FFI `cadence_model_verify` gate; ADR-0007). Remaining:
   **idle model unload (<150 MB)** — designed, deferred (tension w/ ~7 s cold load, ADR-0006);
   asymmetric signature verify (needs signing key); full registry-resolve over FFI + a manifest
   in the shell.
4. **Encrypted store SHIPPED (2026-07-18): first §24 slice live.** `core/store`
   (`cadence-store`): SQLCipher via rusqlite `bundled-sqlcipher-vendored-openssl` (no system
   deps, no admin), schema v1 = utterances (full §24 shape + `extra_json` for shell metrics)
   + settings KV + app_rules + models tables, forward-only migrations via `user_version`.
   Key custody: 32-byte random key in the login keychain (`dev.cadence.app`/`store-key`,
   non-synchronizable — local-first), created on first launch by the shell; core sees raw
   bytes only at open (SQLCipher raw-key pragma, no KDF latency). FFI: `cadence_store_open/
   free/persist_json/recent_json/import_jsonl/string_free` (header updated). Shell:
   `HistoryStore.swift`; router persists via store with **JSONL fallback on any failure
   (AC-22 — store is an upgrade, never a gate)**; dashboard reads store-first. One-time
   JSONL import on first launch: **verified live — 19 records imported, JSONL renamed
   `.imported` (kept, not deleted)**. Encryption verified on the live files: 0 plaintext
   hits in db+WAL (plaintext JSONL: 9), header is ciphertext. Wrong key fails closed
   (BadKey), pinned by tests at both the crate and C-ABI layers. Tests 79/79.
   Still §24-open: audio_blobs (audio retention off), dictionary/corrections/style/
   redaction/sync tables, registry `ModelStore` impl over the models table, retention/purge.
   E2E persist of a *new* dictation not yet observed live (user was active; next real
   dictation is the check — `History & Metrics` should show it, and history.jsonl must NOT
   reappear).
5. **Undo + per-app rules + AC-20 verification SHIPPED (2026-07-18):**
   - **Post-insert verification (closes the blind-paste gap):** `InsertionResult` gains
     `verification: verified | unverifiable | contradicted`. pasteRestore reads back the
     focused element AFTER the paste, BEFORE the clipboard restore: a readable value that
     lacks the text tail = `contradicted` → reported as NOT inserted, restore skipped so
     the words stay one ⌘V away (§29), user sees "saved to clipboard". Opaque targets
     (VS Code, web views, Spotlight) stay `unverifiable` and are trusted exactly as before —
     the 6/6 matrix behavior is unchanged. Direct-AX keeps its built-in readback
     (= `verified`). Verification is logged + persisted per utterance (`verification` in
     history extra).
   - **Undo (F21/§26):** ⌃⌥⌘Z global chord (CGEvent tap, consumed) + menu item "Undo Last
     Dictation". Router keeps an `UndoRecord` (app, text, time) written at insert, armed by
     the core's `arm_undo` (fires only on confirmed insertion). Fire guards: armed + idle +
     same app still frontmost (else pill says "switch to X to undo") + ≤2 min fresh; then
     one ⌘Z — insertions land as a single undoable unit (one paste / one AX set), so the
     target reverts exactly that. Standard in-app ⌘Z keeps working independently (§26).
   - **Per-app rules (first slice):** menu toggle "Disable in <frontmost app>" (LSUIElement
     ⇒ opening our menu doesn't steal frontmost; captured in `menuNeedsUpdate`). Persisted
     in the store settings KV (`disabled_apps`, new FFI `cadence_store_setting_get/set`),
     cached in the shell so PTT-down never touches the DB. A swallowed PTT-down also
     swallows its up (no orphan trigger_up). Pill shows "‖ off here", fades.
   - Tests 79/79 (settings KV pinned over the C ABI). LIVE RE-TESTS PENDING: dictate then
     ⌃⌥⌘Z (should revert + "undone" pill); menu toggle in some app then PTT there ("off
     here" pill, no capture); Pages page-layout blind-paste should now report "saved to
     clipboard" instead of a false success.
6. **Idle model unload SHIPPED (2026-07-18):** the ASR worker drops the whisper engine
   (~200 MB model + Metal buffers) after 5 min without ASR work (`CADENCE_UNLOAD_SECS`
   env override; 0 disables) and reloads via a factory on the next dictation — warm-up
   decode re-run, audio_ctx cap re-applied. Reload is worn as a longer "thinking" (~200–
   500 ms warm); capture is unaffected (ring buffers regardless). Reload failure fails
   only that utterance through the existing no-lost-words path (partial jobs release the
   scheduler latch, final jobs → AsrFailed) and retries next time. Regression-pinned:
   `idle_unload_reloads_transparently_on_next_dictation` (1 s unload window, full dictation
   after). 80/80 workspace + 11/11 FFI-whisper. Closes the last §28 idle-budget miss
   **CONFIRMED LIVE (qa/unload-verify.jsonl): 177 MB → 36 MB at exactly the 5-min mark —
   §28 idle budget MET with 4× margin.** All three idle targets now green.
7. **Retention + registry-over-DB (2026-07-18):** `purge_utterances_older_than_days`
   (`retention_days` setting, unset/0 = keep forever; shell runs it at open via
   `cadence_store_purge_utterances`) and `impl cadence_models::ModelStore for Store`
   (schema v2: `models.bundled` column; save is transactional whole-set replace). v1→v2
   migration ran clean on the live store. 82/82. §24 remainder: audio_blobs,
   dictionary/corrections/style/redaction/sync tables; a Settings UI for retention.
8. **audio_blobs SHIPPED (2026-07-19): §24 retained audio, opt-in, off by default.**
   Schema v3 (`audio_blobs`): deliberate deviation from the blueprint sketch — audio is an
   in-row `data BLOB` under the same SQLCipher key, not a `path` to a sidecar file (which
   would need its own encryption + key custody). `secure_delete=ON` at open makes purges
   zero freed pages ("hard delete + secure blob erase", §24). Store API: `put/get/
   delete_audio_blob` + `purge_expired_audio_blobs` (absolute `purge_after` epoch-ms
   deadline stamped at write; NULL = lives and dies with its utterance — the utterance
   retention purge cascades to referenced blobs in one transaction). `UtteranceRecord`
   gains `audio_blob_id` (column existed since v1; now read/written + in record JSON).
   FFI: `cadence_store_audio_put/get/delete/purge_expired` + `cadence_bytes_free`, header
   updated. Shell: menu toggle "Keep Audio Recordings" (`retain_audio` setting, cached —
   PTT never touches the DB); router tees capture chunks into a lock-guarded per-utterance
   accumulator (armed before tap start, cleared on cancel/discard), `persist_utterance`
   hands samples to `HistoryStore` which writes a 16 kHz mono WAV (`WavWriter`, canonical
   44-byte header, no AVFoundation) blob then links it in the record. Blob deadline:
   `audio_retention_days` setting wins, else `retention_days`, else none; expired-blob
   purge runs at every launch. Audio is best-effort: blob failure keeps the transcript
   (AC-22); redacted utterances never retain audio; audio never goes to the JSONL
   fallback. Tests 86/86 (blob roundtrip+link, expiry purge + ref-clearing, retention
   cascade, v2→v3 forward migration, full C-ABI roundtrip). dist/Cadence.app repackaged —
   v2→v3 migration will run on next launch of the installed app. LIVE CHECKS PENDING:
   toggle "Keep Audio Recordings", dictate, confirm a WAV-shaped blob row + linked
   `audio_blob_id` in history; playback UI is future work (dashboard doesn't surface
   audio yet). §24 remainder: dictionary/corrections/style/redaction/sync tables; a
   Settings UI for retention windows.
9. **Daily-driver hardening (2026-07-19, b5439a7):** push toward "casual daily use".
   - **Model tier decision (§30):** WER harness re-run — small.en 3.11% vs base.en 5.78%
     (225 ref words), refined ~350-450 ms / partials ~270-420 ms on M4 (vs base's ~115 ms
     refined). Accuracy is the daily-use bottleneck (~90% felt), so **small.en is now the
     bundled model**; base.en remains the §17.5 golden rollback. Both sha256-pinned in
     fetch-models.sh. Idle unload caps the RAM cost (bigger model only resident while
     dictating + 5 min).
   - **Static-link fix (shipped-app integrity):** cadence-ffi built cdylib+staticlib; the
     Swift linker preferred the dylib and bound the installed app to the ABSOLUTE dev-tree
     path — any `cargo build` without `--features whisper` silently broke the installed
     app ("built without the whisper feature", hit live). crate-type is now staticlib+rlib
     only; verified 0 dylib refs, whisper symbols in-binary.
   - **Quit SIGABRT fixed (every quit crashed):** ggml Metal teardown asserts in atexit if
     the device is alive at exit; engine freed before NSApp.terminate (menu quit +
     applicationWillTerminate for ⌘Q/AppleScript). Verified live: clean quit, no new .ips.
   - **Route-change capture failure fixed (hit live 7/19 10:43):** after a route change
     the retry used inputNode's stale sample rate. start() hard-resets the engine before
     retrying; ensureTap re-validates the installed tap's format against hardware.
     AirPods plug/unplug while idle remains the live confirmation.
   - **Menu:** "Start at Login" (SMAppService.mainApp) + "Keep History" retention submenu
     (Forever/90/30/7; purge applies immediately on shortening).
   86/86 + 11/11 whisper-FFI. Repackaged + reinstalled with small.en; launch "core ready"
   221-376 ms. LIVE CHECKS PENDING (Daniel): dictation accuracy feel on small.en; latency
   feel (thinking is ~250-450 ms now); AirPods route change; Keep Audio Recordings blob
   write; Start at Login across a reboot.
5. Windows environment → port insertion spike + this FFI (header already C-clean).
