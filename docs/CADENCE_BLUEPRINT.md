# Cadence — Voice-First Productivity Platform
### Implementation Blueprint (PRD + TDD + UX Specification + Engineering Roadmap)

> **Purpose of this document.** This is a complete, self-contained implementation blueprint written for an AI engineering agent (**Fable**) and a team of senior engineers who have **never used Wispr Flow** and must build a superior product from this document alone. It reverse-engineers Wispr Flow (the market-leading AI dictation app, wisprflow.ai — frequently misheard as "Whisper Flow") from first principles, dissects why it works and where it fails, benchmarks the competitive field, and specifies a product — codenamed **Cadence** — engineered to surpass it.
>
> **Scope note.** No application code appears here by design. Everything below is specification: requirements, architecture, contracts, schemas, acceptance criteria, and rationale. Where a claim about a competitor is drawn from public research it is treated as *reported* rather than *verified fact*; design decisions never depend on a single unverified number.
>
> **Codename.** "Cadence" is a working name (rationale: it evokes the natural rhythm of speech and the flow-state the product protects). Final branding is out of scope.

**Document status:** v1.2 — post two self-critique/revision passes (see §33 Self-Critique Log).
**Target platforms (v1):** macOS 13+ (Apple Silicon + Intel), Windows 11 (10 best-effort). Mobile (iOS/Android) is v2.
**Primary author role:** product research, UX strategy, staff architecture, technical writing.

---

## Table of Contents

1. Executive Summary
2. Product Vision
3. Product Philosophy
4. Core Design Principles
5. User Personas
6. Jobs To Be Done
7. Feature Inventory
8. Competitive Analysis
9. UX Principles
10. Complete User Flows
11. Information Architecture
12. Interaction Design
13. Animation Guidelines
14. Design Language
15. Accessibility Requirements
16. Technical Architecture
17. AI Architecture
18. Voice Pipeline
19. Local vs Cloud Strategy
20. Privacy Model
21. Security Model
22. Data Flow
23. API Recommendations
24. Database Schema
25. Folder Structure
26. State Management
27. Component Inventory
28. Performance Targets
29. Error Handling Strategy
30. Testing Strategy
31. Acceptance Criteria (per feature)
32. Engineering Roadmap & Implementation Order
33. Self-Critique Log (issues found → resolved)
34. Version 2 Opportunities
35. Appendices (glossary, source notes)

---

## 1. Executive Summary

**What the category is.** A new class of desktop utility has emerged since ~2023: the *system-wide AI dictation layer*. You press a hotkey anywhere in the OS, speak naturally, and clean, punctuated, context-formatted text appears at your cursor — in Gmail, Slack, Cursor, Notion, a terminal, anywhere with a text field. Unlike 2010-era dictation (verbatim, robotic, per-app), these tools use an LLM to *edit* the transcript: strip filler words, fix punctuation, restructure into lists, and adapt tone to the target app. Wispr Flow is the market leader; Superwhisper, Aqua Voice, MacWhisper, and Raycast's dictation are the main challengers.

**Why users love Wispr Flow.** Three things: (1) it removes the *cognitive tax* of typing — you think out loud and coherent text appears; (2) the LLM cleanup is genuinely good — the output looks like something you'd have typed, not a raw transcript; (3) it works *everywhere* via a single hotkey, so it disappears into the workflow. Reported end-to-end latency target is <700 ms at p99 (a fine-tuned Llama cleanup model on Baseten/AWS), which is fast enough to feel conversational.

**Where Wispr Flow falls short (the opening).**
- **No offline/on-device mode.** 100% cloud. If the network is down, the product is dead. Every keystroke of dictation — plus *on-screen context around your cursor* — leaves the machine. This is both a reliability liability and a privacy liability.
- **Reliability degradation is the #1 organic complaint.** A recurring pattern in reviews: great during trial, "works 60% of the time" after paying. Trustpilot ~2.7/5 (consumer) vs G2 4.5/5 (enterprise) — a stark split.
- **Resource hog.** The Windows client is reported to idle at ~800 MB RAM / ~8% CPU and to *freeze target apps* (VS Code, Notepad++) during insertion — a text-injection architecture problem.
- **Privacy blowback.** Viral Reddit threads documented active-window screenshot capture and aggressive auto-launch/login-item behavior; training-on-user-data was opt-out before becoming opt-in. Trust, once dented, is hard to win back.
- **Accuracy is good but not best-in-class on hard content.** Independent-style comparisons put Wispr's WER materially above Aqua Voice on email/technical dictation. Uncommon names, code identifiers, and code-switching remain weak.
- **Text insertion is fragile.** Clipboard-paste as the primary injection path clobbers the user's clipboard and breaks in terminals, password fields, and some Electron/web apps.

**What Cadence does differently (the thesis).** Cadence wins on **five axes Wispr under-serves**: *reliability*, *privacy*, *insertion robustness*, *accuracy on hard content*, and *trust*. Concretely:

1. **Local-first, cloud-optional hybrid.** A fast on-device ASR (streaming Parakeet/Whisper-class) + a small on-device cleanup model give a *fully offline* baseline that always works. Cloud is an *opt-in accelerator* for the highest-quality cleanup and heavyweight commands — never a hard dependency. The user always knows, per-utterance, whether audio left the device (a persistent lock/cloud indicator).
2. **Insertion that never corrupts state.** A capability-detecting insertion engine that prefers direct text-service APIs (macOS Accessibility `AXReplaceRange`/marked-text, Windows UIA `TextPattern`/TSF) and *restores the clipboard* when paste is the only option. Never freezes the target app (all injection off the UI thread with hard timeouts and fallback).
3. **Best-in-class accuracy on the content that matters** via context-conditioned ASR, a live personal dictionary (names, code identifiers, jargon), inline biasing from on-screen context, and a two-pass "instant then refine" streaming model so the user sees words immediately and a corrected version settles in.
4. **A trust-first privacy model.** Zero-retention by *default*, on-device by default, explicit and legible data flow, no screenshotting (structured accessibility text only, redaction-filtered), no dark-pattern auto-launch. Privacy is the marketing wedge.
5. **A calm, fast, native-feeling client** with a strict resource budget (idle <150 MB RAM, <1% CPU) and a design language built around a single, beautiful, non-intrusive dictation overlay.

**Business framing (context, not scope).** Freemium (generous offline free tier), Pro subscription for cloud cleanup + commands + sync, Team/Enterprise for admin, SSO, DLP, and compliance (SOC 2 Type II, HIPAA controls). The offline free tier is a *moat*, not a loss-leader: it's the reliability/privacy story competitors can't match without re-architecting.

**One-line vision.** *The fastest way to turn thought into text, everywhere — that always works, and never makes you wonder where your words went.*

---

## 2. Product Vision

**The world we're building toward.** Typing is a lossy, high-friction interface between human thought and the machine. People think at ~150 wpm and type at ~40. Voice closes that gap — but only if the tooling is invisible, instant, private, and *smart enough that the output is better than what you'd have typed*. Cadence is the ambient voice layer of the operating system: always one key away, always trustworthy, equally at home drafting a delicate email, dictating a commit message into a terminal, or restructuring a paragraph you already wrote.

**Three-year north star.** A user should be able to run their entire text-generating workday by voice — messages, docs, code comments, search queries, form fields — with dictation so reliable and so well-formatted that keyboard use becomes the exception, and with a privacy posture so clean that regulated professionals (clinicians, lawyers, finance) adopt it without a second security review.

**What "winning" looks like.**
- A first-time user completes their first successful dictation within **60 seconds** of launch, offline, with zero account required.
- Median perceived latency (stop-speaking → text-settled) **≤ 500 ms** in cloud mode, **≤ 900 ms** fully offline.
- A user can answer "did my audio leave this machine just now?" **correctly, at a glance, every time.**
- Insertion works in **≥ 98%** of the top-100 target apps with **zero clipboard corruption** and **zero target-app freezes**.

**What we are explicitly NOT building.** A meeting transcription/notetaker (that's a different job; see §34 V2). A general voice assistant that takes actions in other apps. A chatbot. A TTS/read-aloud tool. Scope discipline is a feature.

---

## 3. Product Philosophy

1. **Flow is sacred.** The product exists to protect a flow state. Every millisecond of latency, every modal dialog, every "are you sure?", every visual jump is a tax on flow. The default answer to "should we interrupt the user?" is **no**.
2. **The transcript is a draft, not a transcript.** Users don't want what they *said*; they want what they *meant*, formatted for where it's going. Cleanup is the product, not a garnish. But — see #3 — the user must be able to recover the literal words.
3. **Never lose a word.** Dictation is often the *only* copy of a thought. Audio and transcripts are buffered and recoverable even across crashes, network loss, and failed insertions. A failure mode that silently drops the user's words is the cardinal sin.
4. **Local-first, cloud-optional.** The product must be *fully functional* with the network unplugged. Cloud earns its place by being better, not by being mandatory.
5. **Trust is a feature you can lose once.** Privacy defaults are conservative, data flow is legible in the UI, and we never do anything with audio/text that would embarrass us on the front page of Hacker News. No screenshots. No silent training. No dark-pattern launch behavior.
6. **Invisible until summoned, unmistakable when active.** The app has near-zero ambient UI. When listening, its state (idle/listening/thinking/inserting) is *instantly and unambiguously* legible.
7. **Respect the host machine.** A background utility that hogs RAM/CPU or freezes other apps has failed regardless of transcription quality. Resource frugality is a hard requirement, not an optimization.
8. **Correct once, correct forever.** When a user fixes a name, a term, or a formatting choice, the system learns it — locally, immediately — and never makes that mistake again.
9. **Accessible by construction.** This is fundamentally an accessibility product (voice as input for people who can't or prefer not to type). It must itself be operable by screen-reader, keyboard-only, and low-vision users.

---

## 4. Core Design Principles

| # | Principle | Concrete implication |
|---|-----------|----------------------|
| P1 | **Single obvious action** | One primary hotkey (push-to-talk). Everything else is discoverable but secondary. |
| P2 | **Zero-latency perceived start** | Capture audio the instant the key is pressed — before any model is "ready." Never make the user wait to start speaking. |
| P3 | **Two-pass output** | Show fast instant text immediately; settle a refined version in place. The user is never staring at a spinner. |
| P4 | **State is always visible** | The overlay unmistakably shows idle → listening (with live waveform) → thinking → inserting → done, plus a cloud/lock indicator. |
| P5 | **Reversible everything** | Every insertion is undoable in one keystroke; every setting has a sane default; deleting data is confirmed and recoverable for a grace period. |
| P6 | **Fail soft, never silent** | On any error, fall back (cloud→local, direct-insert→paste, paste→copy-to-clipboard-and-notify). The words are *always* recoverable. |
| P7 | **Legible data flow** | The user can always see, per utterance and in settings, exactly what left the device and where it went. |
| P8 | **Frugal by default** | Idle budget: <150 MB RAM, <1% CPU, zero network when not dictating. Models load lazily and unload when idle. |
| P9 | **Personal, on-device** | Personalization (dictionary, style, corrections) lives locally and works offline; cloud sync is opt-in and encrypted. |
| P10 | **Native, not Electron-heavy** | Prefer native shells for the always-on hot path (overlay, capture, injection) to hit latency and resource budgets. |

---

## 5. User Personas

**Persona A — "Maya," the high-volume communicator (primary).**
- Role: PM / founder / exec. Lives in Slack, Gmail, Notion, Linear.
- Pain: 200+ messages/day; typing is the bottleneck; wants polished tone without effort.
- Needs: instant dictation everywhere, tone adaptation (casual in Slack, formal in email), voice editing of drafts.
- Success: clears inbox 2–3× faster; messages read as if carefully typed.
- Sensitivity to: latency (high), formatting quality (high), privacy (medium).

**Persona B — "Devin," the developer (primary).**
- Role: software engineer. Cursor/VS Code, terminal, GitHub, Slack.
- Pain: dictating code identifiers, commit messages, PR descriptions, code comments; standard dictation mangles `camelCase`, `snake_case`, symbols, and library names.
- Needs: code-aware transcription, custom dictionary of identifiers, works in terminal/Electron editors without freezing them, a "code comment" vs "prose" mode.
- Success: writes PR descriptions and Slack updates by voice; terminal never freezes.
- Sensitivity to: insertion robustness (very high), accuracy on technical terms (very high), resource use (high — already runs heavy tools).

**Persona C — "Dr. Reyes," the regulated professional (differentiator).**
- Role: clinician / lawyer / financial advisor.
- Pain: dictates notes constantly; *cannot* have PHI/PII leave the device or be trained on; needs an audit trail.
- Needs: guaranteed on-device mode, zero retention, HIPAA controls, no screenshots, per-app disable (never listen in the EHR unless told), admin policy.
- Success: adopts without a painful security review; can attest that audio never left the machine.
- Sensitivity to: privacy (absolute), reliability (very high), accuracy on domain vocab (high).

**Persona D — "Sam," the accessibility-first user (differentiator + moral core).**
- Role: user with RSI / limited hand mobility / dyslexia.
- Pain: typing is painful or slow; existing OS dictation is inaccurate and breaks in many apps.
- Needs: hands-free/continuous mode, voice commands for editing and navigation, extremely reliable insertion, screen-reader-compatible app UI, robust in *every* app.
- Success: operates their full workday by voice with minimal manual correction.
- Sensitivity to: reliability (absolute), hands-free ergonomics (very high), accuracy (very high).

**Persona E — "Lena," the multilingual/global user.**
- Role: works across English + another language; code-switches mid-sentence.
- Pain: most tools force a single language; code-switching breaks them; names get anglicized.
- Needs: auto language detection, in-utterance code-switching, per-language dictionaries.
- Sensitivity to: multilingual accuracy (high), name accuracy (high).

**Anti-persona (explicitly de-prioritized).** The "record a 1-hour meeting and get a transcript" user — served by MacWhisper-style file transcription. Cadence is *live dictation*, not batch transcription (though §34 covers a v2 bridge).

---

## 6. Jobs To Be Done

Framed as "When ___, I want to ___, so I can ___."

- **JTBD-1 (Compose in place).** When I'm in any text field, I want to speak and have polished text appear at my cursor, so I can write far faster than I type without switching apps.
- **JTBD-2 (Tone-match).** When I dictate into different apps, I want the output tone/format to match the context (Slack casual, email formal, doc structured), so I don't have to re-edit.
- **JTBD-3 (Edit by voice).** When I have text already (mine or dictated), I want to select it and speak a transformation ("make this shorter", "bulletize", "more formal"), so I can revise without typing.
- **JTBD-4 (Dictate technical content).** When I dictate code identifiers, commands, or jargon, I want them spelled/cased correctly, so I don't fix them by hand.
- **JTBD-5 (Work privately/offline).** When I'm on a plane, on a sensitive matter, or just security-conscious, I want dictation to work fully on-device with nothing leaving the machine, so I can trust it anywhere.
- **JTBD-6 (Never lose a thought).** When something fails (network, insertion, crash), I want my words preserved and recoverable, so a bug never costs me an idea.
- **JTBD-7 (Hands-free operation).** When my hands are busy/unavailable, I want continuous dictation and voice control of the app, so I can work without the keyboard.
- **JTBD-8 (Personalize accuracy).** When the tool mishears my names/terms, I want to correct it once and never see that error again, so accuracy improves over time.
- **JTBD-9 (Trust & verify).** When I dictate, I want to know exactly what data left my device, so I can meet my own/organizational privacy bar.
- **JTBD-10 (Multilingual).** When I speak more than one language, I want it to keep up and switch seamlessly, so I'm not locked to English.

Each JTBD maps to features in §7 and acceptance criteria in §31.

---

## 7. Feature Inventory

Legend: **[MVP]** = v1 launch, **[Fast-follow]** = within ~1 quarter of launch, **[V2]** = later. Each links to acceptance criteria IDs (§31).

### 7.1 Capture & activation
- **F1 Push-to-talk dictation** [MVP] — hold hotkey to record, release to insert. (AC-1)
- **F2 Hands-free / toggle mode** [MVP] — tap to start, tap (or silence-timeout, or wake-stop) to end; long-form dictation. (AC-2)
- **F3 Continuous/always-listening mode** [Fast-follow] — for accessibility persona; explicit, obvious active state; strong safeguards. (AC-3)
- **F4 Multiple configurable triggers** [MVP] — keyboard hotkeys, mouse-button binds, optional double-tap-modifier; per-mode bindings. (AC-4)
- **F5 Instant-start capture** [MVP] — audio buffered from key-down before models are warm. (AC-5)
- **F6 Barge-in / cancel** [MVP] — press Esc (or dedicated key) to discard current utterance without inserting. (AC-6)

### 7.2 Transcription & cleanup
- **F7 Streaming two-pass transcription** [MVP] — instant partial text, then a refined settle. (AC-7)
- **F8 LLM cleanup** [MVP] — filler removal, punctuation, capitalization, list/structure detection, disfluency repair. (AC-8)
- **F9 Context-aware formatting** [MVP] — adapt tone/format to target app (Slack/email/doc/code/terminal) via app profiles. (AC-9)
- **F10 On-screen context biasing** [Fast-follow] — bias ASR/cleanup using *structured accessibility text* near cursor (opt-in, redaction-filtered, never screenshots). (AC-10)
- **F11 Personal dictionary** [MVP] — user- and auto-learned names, identifiers, jargon; casing/spelling rules; import from contacts/repo (opt-in). (AC-11)
- **F12 Correction learning** [Fast-follow] — detect user edits post-insert; learn locally; stop repeating errors. (AC-12)
- **F13 Multilingual + code-switching** [MVP for top languages; Fast-follow for full breadth] — auto-detect, in-utterance switching, per-language dictionaries. (AC-13)
- **F14 Whisper/quiet-speech capture** [Fast-follow] — usable in shared quiet spaces. (AC-14)
- **F15 Verbatim/literal mode** [MVP] — disable cleanup for exact transcription (e.g., quotes, legal). Always recover literal text. (AC-15)

### 7.3 Voice editing & commands
- **F16 Command Mode (select-then-speak)** [MVP] — select text, speak transformation; robust selection capture and replacement. (AC-16)
- **F17 Inline dictation commands** [Fast-follow] — "new line", "new paragraph", "scratch that", "cap that", "bullet list" recognized during dictation. (AC-17)
- **F18 Custom modes/prompts** [Fast-follow] — user-defined modes (own prompt, model, hotkey, auto-activate rule per app). (AC-18)
- **F19 Snippets/macros** [V2] — voice-triggered text expansion ("insert my address"). (AC-19)

### 7.4 Reliability & recovery
- **F20 Robust insertion engine** [MVP] — capability cascade (direct API → TSF/marked-text → clipboard-with-restore → notify+copy); no target-app freeze; per-app strategy overrides. (AC-20)
- **F21 Undo last insertion** [MVP] — single keystroke reverts the exact inserted range. (AC-21)
- **F22 Dictation history & recovery** [MVP] — recent utterances (audio + both transcript passes) locally, searchable, re-insertable; survives crash. (AC-22)
- **F23 Offline mode** [MVP] — full local pipeline; automatic + manual toggle; clear indicator. (AC-23)
- **F24 Graceful degradation** [MVP] — cloud→local, and quality-tier fallbacks, transparent to user. (AC-24)

### 7.5 Trust, privacy, control
- **F25 Data-flow indicator** [MVP] — per-utterance cloud/local + lock indicator; settings page shows exactly what's sent. (AC-25)
- **F26 Zero-retention default** [MVP] — no server storage of audio/transcripts by default; opt-in local history only. (AC-26)
- **F27 Per-app rules** [MVP] — disable/enable, force-local, force-verbatim, or set default mode per app (e.g., never listen in 1Password/EHR). (AC-27)
- **F28 Redaction filters** [Fast-follow] — strip patterns (card numbers, secrets, configurable) before any cloud call. (AC-28)
- **F29 No dark patterns** [MVP] — auto-launch off by default (offered, not imposed); one-click full uninstall/data-wipe. (AC-29)

### 7.6 Personalization & sync
- **F30 Style profile** [Fast-follow] — learns user's punctuation/formatting/tone preferences locally. (AC-30)
- **F31 Encrypted sync** [Fast-follow] — dictionary/settings/style sync across devices, E2E-encrypted, opt-in. (AC-31)
- **F32 Usage insights** [Fast-follow] — words dictated, time saved, accuracy trend; fully local. (AC-32)

### 7.7 Admin / enterprise
- **F33 Team management, SSO/SCIM** [V2] — (AC-33)
- **F34 Policy/DLP controls** [V2] — force-local for org, blocklist apps, retention policy, audit log. (AC-34)
- **F35 Compliance** [V2] — SOC 2 Type II, HIPAA BAA, data residency. (AC-35)

### 7.8 Platform surface
- **F36 Menu-bar/tray app + overlay** [MVP] — minimal ambient UI; settings window. (AC-36)
- **F37 Onboarding** [MVP] — permissions, mic test, first-dictation-in-60s, hotkey teaching. (AC-37)
- **F38 Mobile apps** [V2] — iOS/Android keyboard + dictation. (AC-38)

---

## 8. Competitive Analysis

### 8.1 Feature/architecture matrix

| Dimension | **Wispr Flow** | **Superwhisper** | **Aqua Voice** | **MacWhisper** | **Raycast Dictation** | **Apple Dictation** | **Windows Voice Access** | **Cadence (this doc)** |
|---|---|---|---|---|---|---|---|---|
| Primary job | System-wide AI dictation | System-wide dictation + modes | System-wide dictation + NL editing | File transcription + dictation | Dictation inside launcher | OS dictation | OS dictation + control | System-wide AI dictation, local-first |
| Processing | Cloud only | **Local or cloud** | Cloud (fusion) | Local (Whisper) | Cloud | **On-device (Apple Silicon)** | On-device | **Hybrid, local-first, cloud-optional** |
| Offline | ❌ | ✅ | ❌ | ✅ | ❌ | ✅ | ✅ | ✅ (full) |
| LLM cleanup | ✅ (fine-tuned Llama) | ✅ (GPT/Claude/Llama, per mode) | ✅ (natural-language editing) | Basic | ✅ (hosted GPT-class) | ❌ (verbatim) | ❌ | ✅ (local small + cloud large) |
| Reported accuracy | Good (~higher WER on hard content) | Good (model-dependent) | **Best-in-class (sub-2% WER claims)** | Good (Whisper) | Good | ~96% quiet | Good | Target: match/beat Aqua on email+code |
| Latency | <700 ms p99 (cloud) | Local-dependent | Instant ~450 ms / Streaming ~850 ms | N/A (batch) | Cloud RT | Fast (local) | Fast | ≤500 ms cloud / ≤900 ms local |
| Custom modes/prompts | Limited | ✅ (unlimited, per-mode model+hotkey+auto) | Some | Modes | Some | ❌ | ❌ | ✅ (custom modes + per-app rules) |
| Voice editing | Command Mode (beta, "glitchy") | Via modes | ✅ (strong NL editing) | ❌ | Limited | ❌ | ✅ (navigation/control) | ✅ (Command Mode + inline commands) |
| Platforms | Mac/Win/iOS/Android | Mac/Win/iOS | Mac/Win | Mac | Mac (in Raycast) | Apple | Windows | Mac/Win (v1); mobile v2 |
| Privacy default | Cloud; screen context sent; training opt-in (now) | **Strong (local option)** | Cloud (audio leaves) | Strong (local) | Cloud | Strong (local) | Strong | **Strongest (local default, ZDR, no screenshots)** |
| Resource use | **Heavy (~800MB/8% idle on Win, app freezes)** | Moderate | Light | Moderate | Shared w/ Raycast | Light | Light | **Frugal (<150MB idle target)** |
| Price (reported) | ~$15/mo | ~$8.49/mo or ~$249 lifetime | ~$8/mo | One-time | Raycast plan | Free | Free | Freemium + Pro (offline free tier is the moat) |
| Compliance | HIPAA-ready, SOC2 (Ent) | — | — | — | — | — | — | HIPAA + SOC2 (roadmap) |

### 8.2 Per-competitor teardown

**Wispr Flow — the leader to beat.**
- *Why it wins:* excellent LLM cleanup, truly system-wide, fast cloud latency, cross-platform including mobile, strong onboarding and polish, enterprise/compliance story. The cleanup model + context-aware tone is the core magic.
- *How it likely works:* client captures mic audio on hotkey; streams to cloud; context-conditioned ASR produces transcript; a fine-tuned Llama "cleanup" model (hosted on Baseten, TensorRT-LLM, AWS) formats/adapts tone within a ~700 ms p99 budget; client injects text (clipboard-paste heavy). Reads on-screen/active-window context and sends it up. Learns from device-level corrections.
- *Where it's weak (our openings):* cloud-only (no offline, hard network dependency, all audio + context leaves device); reliability degradation post-trial is the loudest organic complaint; heavy resource use + app-freezing insertion on Windows; privacy blowback (screenshots, auto-launch, past training defaults); accuracy trails Aqua on hard content; clipboard-based insertion is fragile.
- *Strategic read:* Wispr optimized for cloud quality + growth; it left **reliability, privacy, and host-citizenship** on the table. Those are our wedge.

**Superwhisper — the local-first prosumer tool.**
- *Strengths:* genuine on-device models (Whisper + Parakeet, incl. offline realtime streaming), unlimited custom modes (each with own prompt/model/hotkey/auto-activation), lifetime pricing, strong privacy option, Super Mode (context-aware formatting).
- *Weaknesses:* power-user surface (modes are configuration-heavy for mainstream users); cleanup quality depends on chosen model; less "it just works polished tone" than Wispr out of the box; UX is utilitarian.
- *Lesson for Cadence:* adopt local-first + custom modes, but make the *default* experience mainstream-simple; don't force users into mode configuration to get great output.

**Aqua Voice — the accuracy/editing specialist.**
- *Strengths:* "fusion transcription" + client context engine yields the lowest reported WER (sub-2% on email/tech vs Wispr ~10%); excellent natural-language editing ("make this a list", "redo the second sentence"); Instant (~450 ms) vs Streaming (~850 ms) modes.
- *Weaknesses:* cloud-only (audio leaves device); Mac/Win only, no mobile; narrower ecosystem.
- *Lesson for Cadence:* match the accuracy bar and the natural-language editing UX; but do it with a local baseline so we don't inherit Aqua's cloud dependency. The two-pass Instant/Streaming split is a proven UX — adopt it.

**MacWhisper — the transcription utility.**
- *Strengths:* clean, simple, local file transcription; trusted; one-time price.
- *Weaknesses:* not primarily a live system-wide dictation layer; batch-oriented.
- *Lesson:* different job. Cadence's v2 file-transcription bridge should feel this simple.

**Raycast Dictation — the launcher add-on.**
- *Strengths:* dictation where power users already live (Raycast); good cleanup via hosted GPT-class model.
- *Weaknesses:* cloud-only (stops offline); tied to Raycast; local LLM not in beta.
- *Lesson:* meeting users in their existing surface is powerful (a v2 Cadence Raycast/Alfred/PowerToys extension is worth considering), but a dependency on one launcher caps reach.

**Apple Dictation — the free on-device baseline.**
- *Strengths:* free, on-device on Apple Silicon (~96% quiet), deeply integrated.
- *Weaknesses:* verbatim (no LLM cleanup/tone), breaks in terminals/Electron/password/complex web fields, weak on names/jargon, no custom vocab/modes, limited editing.
- *Lesson:* this is the "why pay?" competitor. Cadence must be *dramatically* better at cleanup, insertion robustness, vocab, and multilingual to justify itself over free.

**Windows Voice Access — the accessibility baseline.**
- *Strengths:* free, on-device, strong voice *control/navigation* (not just dictation), designed for accessibility.
- *Weaknesses:* verbatim dictation, no AI cleanup/tone, utilitarian.
- *Lesson:* Cadence's accessibility persona (Sam) needs some of Voice Access's *control* affordances layered on top of far better dictation.

**ChatGPT Voice / Claude Voice — adjacent, not direct.**
- *What they are:* conversational voice interfaces to an assistant, not system-wide dictation-into-any-field.
- *Overlap/threat:* users increasingly "talk to an AI" to draft text, then copy it out. If OS vendors ship an ambient assistant that also inserts text anywhere, that's the platform-risk to watch.
- *Lesson:* Cadence's defensibility is (a) being *everywhere/in-place* (no copy-paste from a chat), (b) latency, (c) privacy/local, (d) not requiring a conversation to get text. Keep the "just insert, don't chat" purity as the differentiator, while offering an optional "ask" command for when the user wants generation, not transcription.

### 8.3 Positioning statement
> For people who write all day and can't afford unreliable or leaky tools, **Cadence** is the voice-first text layer that works **everywhere, instantly, and fully offline when you need it** — with best-in-class accuracy on the hard stuff (names, code, jargon) and a privacy posture you can actually verify. Unlike Wispr Flow, it never depends on the cloud, never freezes your apps, and never makes you wonder where your words went.

---

## 9. UX Principles

1. **The overlay is the product's face.** 90% of interactions are: press key → speak → see overlay states → text appears. That loop must be flawless, beautiful, and sub-perceptual in latency.
2. **Never block the user's target app.** The overlay is non-activating (does not steal focus); the user's cursor stays where they were typing.
3. **Progressive disclosure.** Default experience needs zero configuration. Power (modes, dictionary, per-app rules) is one settings-click away, never in the hot path.
4. **Teach by doing.** Onboarding gets the user to a real successful dictation in <60 s, then teaches one advanced move (Command Mode) — the rest is discovered contextually via subtle hints.
5. **Every state is honest.** Listening, thinking, degraded-to-offline, error — all visibly and calmly communicated. No fake progress bars.
6. **Latency is a design material.** Because true zero-latency is impossible, *design the wait*: instant partial text, a settling animation, an audio cue on capture start so the user knows to speak immediately.
7. **Undo is a first-class citizen.** Insertion mistakes are inevitable; make reversal trivial and obvious.
8. **Calm, not flashy.** This tool lives in the periphery of focus all day. It must never be loud, jittery, or attention-grabbing. Motion is minimal and purposeful.

---

## 10. Complete User Flows

Notation: **[U]** user action, **[S]** system action, **[UI]** what's shown.

### 10.1 First-run / onboarding — the flagship UX (target: first dictation < 60 s)

Onboarding is the single most important screen sequence in the product: it converts a stranger into someone who has felt the magic *and* trusts the app with their microphone. It must be **beautiful, calm, fast, and confidence-building** — not a checklist. Treat this spec as a first-class design deliverable, not boilerplate.

**North-star principles for onboarding (apply to the whole app):**
- **One decision per screen.** Never stack multiple asks. Each screen has one clear primary action and one obvious "why."
- **Earn each permission the moment before it's needed** — with a plain-language reason *and a live payoff* — never a wall of OS dialogs up front.
- **Show, don't tell.** The user should *speak and see text appear* within the first minute, before they've created an account or read anything long.
- **No account required to feel value.** Signup is offered only after the "wow," and always skippable.
- **Progress is visible and short.** A slim step indicator (e.g., 5 dots). It should feel like it's almost done the whole time.
- **Every screen is reversible** (Back), skippable where safe, and keyboard- + screen-reader-navigable from the first frame.
- **Motion is gentle and purposeful** (§13); respects reduce-motion from screen one.

**Screen-by-screen (each: goal · what's shown · primary action · copy direction · states):**

**Screen 0 — Welcome (≈5 s).**
- *Goal:* set the promise in one breath. *Shown:* the mark, one headline, one subline, a single **Get started** button. A quiet ambient animation (a waveform resolving into clean text) demonstrates the product in 2 seconds with zero words.
- *Copy:* headline "Speak. It becomes writing." · subline "Press one key, talk, and polished text appears — in any app. Works offline. Your words stay yours." · button **Get started** · tiny link "Already have an account? Sign in."
- *States:* respects light/dark; the demo animation has a static reduce-motion fallback.

**Screen 1 — Microphone (the only hard requirement).**
- *Goal:* grant mic *and immediately prove it works*. *Shown:* a friendly explanation ("Cadence listens only while you hold your key. Nothing is recorded otherwise."), a big **Enable microphone** button that triggers the OS prompt.
- *On grant:* the screen transforms into a **live waveform** reacting to the room — the first dopamine hit ("it can hear me"). A prompt: "Say hello 👋". As they speak, **instant transcription appears** — running **fully on-device** (bundled local model), proving offline capability before any cloud/account.
- *Fail path:* if denied, a calm recovery card with the exact OS steps (deep-link to the settings pane where possible) and a **Try again** button — never a dead end.

**Screen 2 — Let Cadence type for you (insertion permission).**
- *Goal:* grant Accessibility (macOS) / input+UIA (Windows) with a concrete payoff. *Shown:* a one-line reason ("This is how Cadence places text where your cursor is — like a keyboard.") and **Enable typing**.
- *On grant:* a live sandbox text box appears with the prompt "Hold **[key]** and say your favorite meal." When they do, **the text lands in the box** — this is the first *real* end-to-end dictation and the core "wow." A subtle success chime + a check.
- *Fail path (critical, must be graceful):* if not granted, Cadence still works in a **degraded-but-useful** mode — transcribes into a floating panel and copies to clipboard — with a persistent, non-nagging banner "Enable typing to insert directly" and a one-tap re-grant. The user is never blocked from experiencing dictation.

**Screen 3 — Make it yours (hotkey + one preference).**
- *Goal:* confirm/choose the trigger and set exactly one taste preference. *Shown:* the default push-to-talk key with 3 curated presets (and "customize"), plus a single, delightful **tone toggle**: "Match my apps automatically" (default ON) vs "Keep it exactly as I say it (verbatim)." That's it — no settings dump.
- *Copy:* "Hold this key anywhere to talk. You can change it any time."
- *State:* live conflict-check on custom binds (rejects OS-reserved combos with a friendly note).

**Screen 4 — Where your words go (trust moment).**
- *Goal:* build trust with a 15-second, honest data-flow explainer — turning privacy into a feature, not fine print. *Shown:* a simple animated diagram: "By default, everything runs **on your device**. Turn on cloud later for extra polish — you'll always see a badge showing exactly where each dictation was processed." A single toggle: **Stay fully offline** vs **Use cloud when it helps (recommended)** — default is Hybrid, clearly labeled, changeable anytime.
- *No dark patterns:* launch-at-login is presented here as an **off-by-default** checkbox with a plain reason, never pre-checked.

**Screen 5 — You're ready (+ optional account).**
- *Goal:* land the user in a confident "go" state and *softly* offer an account. *Shown:* "You're set. Press **[key]** in any app and start talking." A looping micro-hint pointing to the menu-bar/tray icon. Below: an **optional, skippable** card — "Create a free account to sync your dictionary across devices and unlock cloud polish" with **Maybe later** given equal visual weight.
- *Exit:* the window gracefully minimizes to the menu bar/tray; a one-time, dismissible coach-mark near the tray icon appears the first time they leave the window.

**Post-onboarding contextual teaching (not upfront):**
- The first time the user selects text in another app, a subtle, dismissible tip introduces **Command Mode** ("Select text, hold [key], and say 'make this shorter'").
- The first offline fallback shows a one-time "You just went offline and Cadence kept working" reassurance.
- Tips are **rate-limited, dismissible, and never modal** — max one per session, and they stop once the user demonstrates the behavior.

**Onboarding success metric (instrument this):** % of new users who complete a *real* dictation that lands in a field (Screen 2 payoff) within 60 s, and % who reach Screen 5. These are the funnel's north-star numbers (§30 funnel test, AC-37).

- **Fail paths (summary):** mic denied → recovery card with deep-linked steps + retry; accessibility/UIA denied → degraded floating-panel + clipboard mode with persistent one-tap re-grant, never blocked; slow/low-end hardware detected → onboarding transparently selects the "lite" local model and sets expectations ("optimized for your Mac"); no network → onboarding completes 100% offline (it never needs the network).

### 10.2 Core dictation (push-to-talk)
1. [U] In any app's text field, holds the hotkey.
2. [S] *Immediately* begins capturing audio (buffered) + plays a subtle earcon; overlay appears near cursor/screen anchor in **Listening** state with live waveform. (No focus steal.)
3. [U] Speaks.
4. [S] Streaming ASR emits partial text → overlay shows live **instant** transcript (pass 1).
5. [U] Releases the hotkey.
6. [S] Finalizes audio; overlay → **Thinking**; runs final ASR + cleanup (local or cloud per mode/availability).
7. [S] Overlay → **Inserting**; insertion engine places refined text at the cursor (pass 2 replaces pass-1 preview if pass-1 was inserted live; see §12 for the two-pass insertion contract).
8. [UI] Overlay → brief **Done** confirmation (word count, cloud/local indicator), then fades.
9. [S] Utterance stored in local history (if enabled). Undo armed.
- **Fail paths:** network loss mid-cloud → auto-fallback to local, indicator flips to "offline," no user action needed; insertion target lost focus → text copied to clipboard + toast "Cadence copied your text — paste with ⌘V"; ASR empty (silence) → no insertion, gentle "didn't catch that."

### 10.3 Hands-free / long-form
1. [U] Taps toggle hotkey (or says wake-stop word if enabled).
2. [S] Enters continuous listening; overlay shows persistent **Listening** with elapsed time + live text panel.
3. [U] Speaks in paragraphs; pauses are handled (VAD segments; no accidental stop on natural pauses).
4. [S] Inserts settled text incrementally at cursor; inline commands ("new paragraph") honored.
5. [U] Taps toggle again (or silence-timeout) to stop.
- **Safeguard:** a persistent, unmissable "LISTENING" indicator + optional auto-timeout so the mic is never hot unexpectedly.

### 10.4 Command Mode (edit by voice)
1. [U] Selects text in any app, holds the Command-Mode hotkey.
2. [S] Captures the current selection (via accessibility read of selected text) + records the spoken instruction.
3. [U] Says e.g. "make this more concise and add a friendly closing."
4. [S] Sends {selected text + instruction + app/context} to cleanup/instruct model (local small model for simple ops; cloud large model for complex); overlay → **Thinking**.
5. [S] Replaces the selection with the transformed text (insertion engine, exact-range replace). Undo armed; original preserved in history.
- **Fail paths:** no selection detected → "Select some text first, then hold [key]"; selection unreadable in target app → fallback to "read from clipboard" prompt.

### 10.5 Going offline / degraded
1. [S] Detects no network (or cloud error/timeout).
2. [UI] Indicator flips to a calm "Offline — running on-device" chip (not an error).
3. [S] All dictation continues via local pipeline; cloud-only features (heavy commands) gracefully show "available online" and offer the local-quality version.
4. [S] On reconnect, silently restores cloud tier; no interruption.

### 10.6 Correcting & learning
1. [U] After an insertion, fixes a misheard name by typing.
2. [S] (If correction-learning enabled) detects the edit within the inserted range; proposes adding the corrected term to the personal dictionary via a subtle, dismissible chip.
3. [U] Accepts (or ignores).
4. [S] Adds term locally; future dictations bias toward it. No repeat error.

### 10.7 Privacy review
1. [U] Opens Settings → Privacy.
2. [UI] Plain-language dashboard: current mode (local/cloud), zero-retention status, what's sent when cloud is used, per-app rules, redaction filters, one-click "export/delete all local data," "wipe & uninstall."
3. [U] Sets "always local" globally or per-app; toggles on-screen context off/on.

### 10.8 Uninstall
1. [U] Chooses uninstall from settings or OS.
2. [S] Removes login item, models, local data (after a clearly-stated grace-period option to export), revokes nothing silently, confirms complete removal. No re-launch, no residue.

---

## 11. Information Architecture

**Surfaces:**
- **Overlay (HUD):** transient, non-activating, near-cursor or fixed anchor. States only. No navigation.
- **Menu-bar/Tray icon + menu:** quick toggles (mode, mute/disable, offline lock), "open history," "settings," pause/resume, quit.
- **Main window (Settings/Console):** tabbed.

**Settings/Console IA:**
```
Cadence
├── Home / Status
│   ├── Ready state, current mode, cloud/local indicator
│   ├── Quick stats (words today, time saved) [local]
│   └── Recent activity (last few dictations)
├── Dictation
│   ├── Triggers & hotkeys (per mode, mouse binds)
│   ├── Modes (built-in + custom; per-mode: prompt, model, hotkey, auto-activate app rules)
│   ├── Formatting defaults (verbatim toggle, punctuation style, tone default)
│   └── Language(s) & code-switching
├── Personalization
│   ├── Dictionary (names, identifiers, jargon; import; casing rules)
│   ├── Style profile (learned; editable/resettable)
│   └── Correction learning (on/off, review learned items)
├── Privacy & Security
│   ├── Processing location (local-only / hybrid / cloud-preferred)
│   ├── Zero-retention & history controls (retention window, encryption)
│   ├── On-screen context (off by default; scope; redaction filters)
│   ├── Per-app rules (disable / force-local / verbatim / default mode)
│   └── Data: export all, delete all, wipe & uninstall
├── History
│   ├── Searchable list (audio + instant + refined transcript)
│   ├── Re-insert / copy / delete
│   └── Retention & auto-purge settings
├── Account & Sync (optional)
│   ├── Sign in (Pro/Team), plan, usage
│   └── Encrypted sync (dictionary/settings/style) toggle
├── Accessibility
│   ├── Hands-free/continuous config & safeguards
│   ├── Overlay size/contrast/position, reduce-motion, sounds
│   └── Screen-reader announcements
├── Team/Admin (enterprise) [V2]
│   ├── Policies (force-local, app blocklist, retention)
│   ├── SSO/SCIM, seats, audit log
└── About / Help
    ├── Diagnostics (opt-in, redacted), logs export
    └── Permissions health check
```

**Global states surfaced everywhere:** Processing location (local/cloud), Listening/Idle, Offline, Disabled-for-this-app, Error.

---

## 12. Interaction Design

### 12.1 The overlay (HUD) — the heart of the product
- **Placement:** by default a compact pill anchored near the text cursor when its location is derivable (via accessibility caret bounds), else a fixed, user-chosen screen edge/corner. Never covers the caret. Non-activating window (macOS: `NSPanel` non-activating / Windows: `WS_EX_NOACTIVATE` layered/topmost) so focus stays in the target field.
- **Size:** small by default (~a large tooltip). Expands to a text panel only in hands-free/long-form or when showing a command result preview.
- **Anatomy:** [state glyph] · [live waveform | text] · [cloud/local + lock chip] · [mode label]. Optional word count on Done.

### 12.2 State machine (visible states)
```
IDLE ──(hotkey down)──► LISTENING ──(release/stop)──► THINKING ──► INSERTING ──► DONE ──(fade)──► IDLE
   │                         │                            │
   │                         └─(Esc/cancel)──► CANCELLED ─┘ (no insert)
   └─(disabled-for-app)──► DISABLED (chip only)
Any state ──(cloud fail)──► same state, indicator flips to OFFLINE
Any state ──(unrecoverable error)──► ERROR (text preserved to clipboard/history)
```
- **LISTENING:** live waveform reacts to input level (confirms mic is hearing you — critical trust signal). Instant partial text streams if enabled.
- **THINKING:** subtle indeterminate motion (breathing/pulse), never a fake percentage.
- **INSERTING:** brief; the text lands in the target field.
- **DONE:** 400–700 ms confirmation, then fade.

### 12.3 Two-pass insertion contract (critical detail)
Two supported strategies, selectable per mode; **default = "Settle-in-place"**:
- **A. Preview-in-overlay, insert-once (default for short PTT):** pass-1 instant text shows *only in the overlay*; nothing is inserted into the target until the refined pass-2 text is ready, then a single insertion occurs. Pro: never inserts wrong text into the doc; Con: user waits ~pass-2 latency to see text in-field. Best when pass-2 is fast (<500 ms).
- **B. Insert-instant-then-replace (Aqua-style streaming, for long-form/low-latency):** pass-1 text is inserted live; when pass-2 settles, the engine computes a minimal diff and replaces only changed ranges in-field. Pro: text appears instantly; Con: requires reliable range replacement (guard against user typing into the range mid-flight — if the user edits within the pending range, *abandon* the auto-replace and keep pass-1 to avoid clobbering their edit). 
- The engine must **detect user interference** (focus change, caret move, edits within pending range) and safely abort replacement, always preferring "don't corrupt the user's document" over "apply the refinement."

### 12.4 Hotkey & trigger design
- Default push-to-talk: a modifier that's ergonomic and rarely conflicting (e.g., **hold Right-Option/Right-Alt**, or **Fn** where available) — validated against OS reservations; user-rebindable. (Choose defaults empirically in beta; provide 3 curated presets.)
- Toggle hands-free: separate binding (e.g., double-tap the PTT modifier).
- Command Mode: separate binding.
- Cancel: **Esc** while overlay active.
- Undo insertion: standard **⌘Z/Ctrl+Z** must work because we insert as a single undoable unit in the target app *where possible*; additionally a dedicated "undo Cadence insertion" global hotkey as fallback.
- Mouse-button binds and per-mode bindings supported.

### 12.5 Command grammar (inline, during dictation)
Recognized literal commands (configurable, localizable): "new line", "new paragraph", "scratch that / delete that" (removes last sentence/segment), "cap that", "all caps", "bullet point / new bullet", "numbered list", "quote … unquote", "open/close parenthesis", "period/comma/question mark" (when in verbatim/punctuation-explicit mode). Ambiguity policy: if a phrase could be content or command, prefer content unless in an explicit command context; expose a "literal punctuation" mode for users who want to speak punctuation.

### 12.6 Feedback & earcons
- Distinct, subtle sounds (user-mutable): capture-start, capture-cancel, insertion-done, error. Sounds are essential for the eyes-free/accessibility persona and for confidence that capture began the instant the key went down.

---

## 13. Animation Guidelines

- **Purpose over decoration.** Every animation communicates a state change or masks unavoidable latency. No motion for delight alone.
- **Durations:** micro-transitions 120–180 ms; overlay appear/dismiss 150–220 ms; Done→fade 400–700 ms. Nothing that delays perceived responsiveness.
- **Easing:** standard ease-out for entrances, ease-in for exits; the "thinking" pulse is a slow (~1.2 s) sinusoidal breathing at low amplitude.
- **Waveform:** 60 fps live audio-level visualization while listening (falls back to 30 fps / simplified bars under load or reduce-motion). It must be driven by *real* input level (trust signal), not a canned loop.
- **Settle animation (pass-1→pass-2):** when text is replaced in-overlay, cross-fade/character-diff subtly so it reads as "refining," not "flickering."
- **Reduce-motion:** honor OS "reduce motion." Replace waveform with a simple pulsing dot; replace transitions with instant state swaps; no cross-fades.
- **Never:** bouncy/springy overshoot, attention-grabbing color flashes, spinners implying fake progress, motion during INSERTING that competes with the target app.
- **Performance guard:** overlay rendering must never contend with ASR/insertion; run on a separate render path; degrade animation before ever degrading pipeline latency.

---

## 14. Design Language

- **Tone:** calm, precise, confident, trustworthy. "A quiet instrument," not "a loud gadget."
- **Color:** neutral, near-monochrome base (adapts to OS light/dark and accent color). A single functional accent for the *active listening* state. **Semantic status colors:** local/secure = calm green-teal lock; cloud = neutral blue with an explicit cloud glyph; offline = amber (informational, not alarming); error = restrained red used sparingly. Status must never rely on color alone (add glyph + label) for accessibility.
- **Typography:** system UI font (San Francisco / Segoe UI) for native feel and performance; clear hierarchy; generous legibility in the overlay (min 13–14pt equivalent, high contrast).
- **Iconography:** a simple, memorable mark for the app; state glyphs are distinct in shape (not just color): idle=dot, listening=waveform, thinking=pulse ring, inserting=caret/arrow, done=check, offline=cloud-slash, disabled=slash, error=exclamation.
- **The lock/cloud chip:** the single most important brand-trust element. Always present during processing; tapping it opens the privacy explanation for that utterance.
- **Density:** overlay is minimal; settings are comfortable, not cramped; enterprise/admin can be denser.
- **Voice & copy:** plain language, no jargon, no dark-pattern nudging. Errors are honest and actionable ("Cadence couldn't type into this app, so your text is on the clipboard — press ⌘V").
- **Cross-platform:** respect each OS's HIG (menu-bar vs tray conventions, window chrome, notification style) while keeping the overlay identity consistent.

---

## 15. Accessibility Requirements

This is an accessibility product; the app itself must be exemplary.
- **WCAG 2.2 AA** for all settings/console UI: contrast ≥ 4.5:1 (text), focus-visible, logical tab order, no keyboard traps.
- **Screen-reader support:** the app UI is fully navigable and labeled with VoiceOver (mac) and Narrator/NVDA (Windows). Overlay state changes are announced via live-region/accessibility notifications (configurable verbosity) so blind users know listening/thinking/inserting/done without seeing the HUD.
- **Keyboard-only operation:** every function reachable without a mouse; all hotkeys rebindable; no action requires precise pointer targeting.
- **Motor accessibility:** hands-free/continuous mode; large, forgiving hit targets; adjustable/removable timeouts; support for switch-access and mouse-button/foot-pedal triggers; dwell-free operation.
- **Low vision:** overlay size/contrast/position adjustable; respects OS text-size and increase-contrast; never conveys critical state by color alone.
- **Cognitive:** plain language; no time-pressured modals; forgiving undo; predictable behavior.
- **Reduce motion / reduce transparency:** fully honored.
- **Sound-independent and sight-independent:** every earcon has a visual equivalent and vice-versa.
- **Localization/RTL:** overlay and settings support RTL and localized command grammar.
- **Accessibility of the accessibility features:** continuous-mode safeguards (the persistent LISTENING indicator, timeout) must themselves be perceivable in the user's chosen modality.
- **Testing:** ship with an a11y test matrix (VoiceOver, Narrator, NVDA, keyboard-only, 200% zoom, high-contrast, reduce-motion) as release gates (§30).

---

## 16. Technical Architecture

### 16.1 High-level shape
A **native core + optional cloud** architecture with a strict separation between the *always-on hot path* (must be native, frugal, low-latency) and *management UI* (can be heavier).

```
┌──────────────────────── Client (per device) ────────────────────────┐
│  HOT PATH (native: Swift/AppKit on macOS, C++/C#/Win32+WinUI on Win) │
│  ┌───────────┐  ┌──────────────┐  ┌───────────────┐  ┌────────────┐  │
│  │ Hotkey/   │→ │ Audio Capture │→ │ VAD + Ring    │→ │ ASR Engine │  │
│  │ Trigger   │  │ (CoreAudio /  │  │ Buffer        │  │ (local +   │  │
│  │ Manager   │  │  WASAPI)      │  │               │  │  cloud RPC)│  │
│  └───────────┘  └──────────────┘  └───────────────┘  └─────┬──────┘  │
│                                                            ▼          │
│  ┌────────────┐  ┌──────────────┐  ┌───────────────┐  ┌────────────┐  │
│  │ Overlay HUD│← │ Orchestrator │← │ Cleanup Engine │← │ Context &  │  │
│  │ (native)   │  │ (state mach.)│  │ (local sm LLM /│  │ Dictionary │  │
│  └────────────┘  └──────┬───────┘  │  cloud lg LLM) │  │ Provider   │  │
│                         ▼          └───────────────┘  └────────────┘  │
│                  ┌──────────────┐                                     │
│                  │ Insertion    │  (AX / UIA / TSF / clipboard)       │
│                  │ Engine       │                                     │
│                  └──────────────┘                                     │
│  MANAGEMENT (can be cross-platform: e.g. SwiftUI/WinUI, or a shared   │
│  Rust/Tauri core for settings, history, sync UI)                     │
│  ┌────────────┐  ┌──────────┐  ┌──────────┐  ┌───────────────────┐    │
│  │ Local Store│  │ Settings │  │ History  │  │ Sync Client (opt) │    │
│  │ (SQLite +  │  │ Service  │  │ Service  │  │ E2E-encrypted     │    │
│  │ enc. blobs)│  └──────────┘  └──────────┘  └─────────┬─────────┘    │
│  └────────────┘                                        │              │
└────────────────────────────────────────────────────────┼─────────────┘
                                                          ▼ (opt-in, TLS)
┌──────────────────────────── Cloud (optional) ───────────────────────┐
│  API Gateway → { ASR service, Cleanup/Instruct LLM service,          │
│  Sync service, Account/Billing, Admin/Policy, Telemetry (redacted) } │
│  Zero-retention inference path (no audio/transcript persistence)     │
└──────────────────────────────────────────────────────────────────────┘
```

### 16.2 Key architectural decisions & rationale
- **Native hot path (not Electron).** Rationale: latency and resource budgets (§28) are impossible to hit reliably in Electron for always-on audio + overlay + injection; Wispr's ~800 MB/app-freeze problems are partly an insertion+runtime issue. Tradeoff: two native codebases (mac/Win) cost more than one Electron app. Mitigation: share a **Rust core library** (via `cxx`/`swift-bridge` on mac, C ABI on Win) for platform-agnostic logic (orchestration state machine, dictionary, cleanup-prompt assembly, local model runtime bindings, storage, sync, redaction). Only OS-specific shells differ (capture, hotkeys, overlay, insertion).
- **Local model runtime.** Use a portable inference runtime for on-device models (e.g., an ONNX Runtime / GGML-class engine) so the same Rust core drives ASR + small cleanup LLM across platforms, with hardware acceleration (Core ML/Metal on mac, DirectML/ONNX-DML on Win). Rationale: single integration surface, offline capability, predictable memory.
- **Cloud is stateless inference behind a gateway.** No user data at rest on the inference path (zero-retention). Rationale: privacy is the wedge; also simplifies compliance.
- **Everything the user sees is driven by one orchestrator state machine** (shared in Rust core) so mac/Win behavior is identical and testable in isolation.

### 16.3 Threading/process model
- Dedicated real-time audio thread (never blocked by UI or network).
- Orchestrator on its own thread; ASR/cleanup inference on worker threads/pools; insertion off the UI thread with a hard timeout (prevents the "freeze the target app" bug — insertion never blocks and always has a fallback).
- Overlay render thread independent; degrade animation before pipeline.
- Optional separate helper process for model inference to isolate crashes from the always-on capture agent (a model crash must never kill the hotkey listener).

---

## 17. AI Architecture

Three model roles; each has a **local** and (optional) **cloud** implementation:

### 17.1 ASR (speech → text)
- **Local:** a streaming, low-latency ASR (Parakeet-class / Whisper-distil-class) with on-device acceleration; supports partial (instant) hypotheses + a final pass. Context-biasing hook (see 17.4).
- **Cloud:** a higher-accuracy context-conditioned ASR for when the user opts into cloud and wants max accuracy on hard content. Streaming.
- **Two-pass:** *Instant* (fast, lower-accuracy partial shown immediately) → *Refined* (final decode with full context + biasing) — mirrors Aqua's Instant/Streaming split, proven UX.
- **Context conditioning (like Wispr):** condition decoding on {personal dictionary, recent-utterance history, app profile, opt-in on-screen text} to resolve ambiguity (names, homophones, jargon).

### 17.2 Cleanup / formatting (transcript → polished text)
- **Local:** a small instruction-tuned LLM (a few-B params, quantized) that removes fillers, fixes punctuation/casing, detects lists/structure, applies verbatim/tone rules from the mode + style profile. Must be fast enough for the local latency budget.
- **Cloud:** a larger, higher-quality cleanup/instruct model for Pro cloud mode and for complex Command-Mode transformations. (Provider-agnostic; for cloud generation/instruct the default recommendation is a current top-tier model — e.g., Claude — behind our gateway. See §23.)
- **Prompt assembly (shared Rust core):** deterministic template combining {mode instructions, target-app profile, style profile, dictionary hints, verbatim flag, the transcript, and — only if opted-in and redaction-passed — nearby context}. Prompts are versioned; outputs constrained (no hallucinated content beyond formatting/instructed transform; verbatim mode forbids semantic change).
- **Guardrail:** cleanup must not *invent* facts. For pure dictation, the model is instructed to preserve meaning and only format. For Command Mode, transformation is intended but bounded by the instruction. A "hallucination guard" compares output to input for dictation mode (length/semantic sanity check) and falls back to lightly-cleaned verbatim if the model drifts.

### 17.3 Instruct / commands (Command Mode)
- Simple ops ("make bullets", "capitalize", "remove filler") → local model.
- Complex ops ("rewrite in the style of my last email", "summarize and add action items") → cloud model (opt-in), or local with lower quality + a note.
- Routing decision is explicit and shown (local/cloud chip).

### 17.4 Personalization stack (all local-first)
- **Personal dictionary:** terms + phonetic/spelling/casing hints; used to bias ASR (contextual biasing / hotword boosting) and to post-correct cleanup. Auto-populated (opt-in) from corrections, contacts, and — for devs — repo symbols/identifiers.
- **Style profile:** learned punctuation density, emoji use, greeting/closing patterns, sentence length; feeds cleanup prompt.
- **Correction learning:** local policy that maps recurring {misheard → intended} to biasing entries. Stored locally; optionally E2E-synced. No server training on user data by default (ever, unless the user explicitly opts into a clearly-labeled improvement program).

### 17.5 Model lifecycle
- Models are versioned, downloaded/updated out-of-band (not bundled into every app update where large), verified by signature/hash, and A/B-guarded (a bad model version can be rolled back client-side). A local "golden" ASR + cleanup model is **bundled** so the app works offline immediately on first run with no download.

---

## 18. Voice Pipeline

End-to-end, with the latency budget (§28) annotated:

1. **Trigger (t=0):** hotkey down → orchestrator → capture starts **immediately**; earcon plays; overlay → LISTENING. (Target overhead <10 ms.)
2. **Capture:** 16 kHz mono PCM from CoreAudio (mac) / WASAPI (Win); pushed to a **ring buffer** so no audio is lost even before models are warm. Echo-cancellation/noise-suppression optional (off by default to preserve fidelity; on for noisy environments).
3. **VAD (voice activity detection):** lightweight on-device VAD segments speech, trims leading/trailing silence, and (in hands-free) detects utterance boundaries and end-of-speech. Guards against premature stop on natural pauses (configurable pause threshold). Whisper/quiet-speech gain handling here (F14).
4. **Streaming ASR — instant pass:** partial hypotheses emitted as the user speaks → overlay live text (pass 1). (Local: runs continuously; Cloud: streamed if cloud mode.)
5. **End-of-utterance (hotkey release / VAD end):** finalize audio window.
6. **ASR — refined pass:** final decode with full context + dictionary biasing + (opt-in) on-screen text → best transcript. (Budget ≤ ~200 ms local/cloud.)
7. **Cleanup:** transcript + assembled prompt → cleanup model → polished text (tone/format per mode+app+style). (Budget ≤ ~200 ms.) Hallucination guard.
8. **Insertion:** insertion engine places text (§16, §12.3). (Budget ≤ ~50–100 ms.)
9. **Persist + arm undo:** store to local history (if enabled); arm undo; overlay → DONE → fade.

**Cloud path:** steps 4/6/7 may run cloud-side behind the gateway (streaming). Network budget ≤ ~200 ms RT (§28). Any cloud timeout/error at step 4/6/7 → **fall back to local** for that utterance, flip indicator to offline, never fail the user.

**Cancellation:** Esc at any point discards the audio + partials, no insertion, capture buffer cleared, overlay → CANCELLED → fade.

**Robustness invariants:**
- The ring buffer + local history guarantee **no lost words** on crash/network loss.
- The instant pass guarantees **no dead air** in the UI.
- The local fallback guarantees **the pipeline never hard-fails** while the mic works.

---

## 19. Local vs Cloud Strategy

**Default = local-first hybrid.** Three user-selectable global policies (plus per-app overrides, §7 F27):

| Policy | ASR | Cleanup | Data leaves device? | For whom |
|---|---|---|---|---|
| **Local-only** | local | local | **Never** | Dr. Reyes; privacy-max; offline |
| **Hybrid (default)** | local instant + cloud refined *if available & allowed* | cloud if available, else local | Only when cloud used, with indicator | Maya, Devin (best balance) |
| **Cloud-preferred** | cloud | cloud (large model) | Yes (with ZDR) | users who want max quality and accept cloud |

- **Automatic degradation:** Hybrid/Cloud-preferred silently fall to Local on network loss/timeout/error. Never blocks.
- **Per-utterance truth:** the cloud/local chip reflects what *actually* happened for *this* utterance (not the policy setting), so a degraded utterance visibly shows "local."
- **Per-app force-local:** e.g., always local in the EHR/1Password/terminal regardless of global policy.
- **Cost/perf tradeoff:** local is free + private + always-available but lower ceiling on hard content; cloud is higher-accuracy + heavier-commands but costs money, requires network, and moves data. The product makes the tradeoff *legible and user-controlled* rather than hidden.
- **Why this beats Wispr:** Wispr = cloud-only (single point of failure + privacy exposure). Cadence's local baseline is the reliability + privacy moat.

---

## 20. Privacy Model

**Principle:** the user can always answer "what left my device?" and the conservative answer is "nothing" unless they chose otherwise.

- **On-device by default.** Local-only and Hybrid both keep audio on-device unless a cloud call is made; Local-only never calls cloud.
- **Zero data retention (ZDR) by default on the cloud path.** Audio/transcripts used for inference are **not persisted** server-side and **not used for training** by default. Any training/improvement program is strictly opt-in, clearly labeled, and revocable.
- **No screenshots. Ever.** Context is gathered *only* as structured text via accessibility APIs, scoped to the focused field's vicinity, **opt-in**, and passed through **redaction filters** before any cloud call. (Directly addresses Wispr's screenshot blowback.)
- **Local history is the user's, encrypted at rest.** Audio + transcripts stored locally (if enabled) with configurable retention and auto-purge; encrypted with an OS-keychain-held key. Off is a first-class option.
- **Redaction filters** strip configurable patterns (payment cards, secrets/API keys, SSNs, custom regex) from both transcripts-going-to-cloud and stored history.
- **Per-app privacy rules:** disable entirely, force-local, or verbatim per app (never listen in password managers by default; ship a sensible default blocklist).
- **Legible data flow:** per-utterance chip + a Privacy dashboard listing exactly what is sent, when, to where; a live "what would be sent" preview.
- **Data subject rights:** one-click export and delete of *all* local + (if account) cloud data; account deletion cascades server-side; documented retention for billing/audit only.
- **No dark patterns:** launch-at-login off by default; permissions requested with rationale and only when needed; uninstall removes everything.
- **Kids/consent/sensitive contexts:** clear notice when continuous listening is on; visible indicator; auto-timeouts.

---

## 21. Security Model

- **Local data at rest:** SQLite + encrypted audio blobs; encryption key in OS keychain/Credential Manager; DB encrypted (SQLCipher-class). History export is user-initiated and warns about plaintext.
- **Transport:** TLS 1.3 for all cloud calls; certificate pinning for the gateway; per-utterance short-lived tokens; no long-lived secrets on device beyond the auth refresh token (stored in keychain).
- **Auth:** OAuth/OIDC; SSO/SAML + SCIM for enterprise (V2); device-scoped tokens; revocation on sign-out.
- **Cloud inference isolation:** stateless workers; no persistence; per-request memory zeroization; tenant isolation; region pinning for data residency (enterprise).
- **E2E-encrypted sync:** dictionary/settings/style sync uses client-side encryption (server stores ciphertext only); key derived from user secret, never on server.
- **Supply chain:** signed/notarized builds (Apple notarization, Windows Authenticode); model artifacts signed + hash-verified before load; dependency pinning + SBOM; reproducible builds where feasible.
- **Permissions least-privilege:** request mic/accessibility/UIA only; no unnecessary entitlements; sandbox where compatible with insertion needs (note: full sandbox may conflict with system-wide injection — document the entitlement rationale, and never ship an over-broad entitlement).
- **Abuse/rate limiting** on cloud endpoints; anomaly detection; DoS protection at gateway.
- **Vuln management:** coordinated disclosure policy, regular pentest, dependency scanning, and — pre-enterprise — SOC 2 Type II + HIPAA controls (BAA) (§7 F35).
- **Threat model highlights:** (1) audio exfiltration → mitigated by local-first + ZDR + no-screenshot; (2) malicious insertion into wrong field → mitigated by focus/target validation before insert; (3) clipboard leakage → mitigated by clipboard restore + preferring direct APIs; (4) model poisoning → signed models + rollback; (5) sync compromise → E2E encryption.

---

## 22. Data Flow

**Dictation, Hybrid mode, cloud available (happy path):**
```
Mic ─PCM→ RingBuffer ─→ VAD ─→ [local instant ASR ─→ overlay partial]
                                └→ (audio window) ──TLS──► Gateway ─► Cloud ASR ─► transcript
transcript + prompt-context(local) ──TLS──► Cloud Cleanup LLM ─► polished text ──► client
client ─► Insertion Engine ─► target app field
client ─► Local History (encrypted, if enabled)      [nothing persisted server-side: ZDR]
```
**Dictation, Local-only:**
```
Mic ─PCM→ RingBuffer ─→ VAD ─→ local ASR ─→ local cleanup LLM ─→ Insertion ─→ field
                                                              └→ Local History (enc.)
   (no network egress at all)
```
**Command Mode (complex, cloud):**
```
Selection (AX/UIA read) + spoken instruction (ASR) ──TLS──► Cloud Instruct LLM ─► transformed text ─► replace selection
   (original preserved in local history for undo)
```
**On-screen context (opt-in):** structured text near caret → **redaction filter (local)** → included in prompt-context only if it passes → sent only on cloud path. Never leaves device in Local-only.

**Sync (opt-in):** local dictionary/settings/style → client-side encrypt → Gateway → encrypted blob store. Server never sees plaintext.

**Telemetry (opt-in, redacted):** anonymized, aggregated metrics (latency, error rates, feature usage) — never audio/transcript content. Default: crash-reporting only, opt-in for usage analytics.

---

## 23. API Recommendations

**Client ↔ Cloud gateway (all opt-in, TLS 1.3, per-request token):**

- `POST /v1/asr/stream` — bidirectional stream: client sends audio frames + context handle; server returns partial + final transcripts. Params: `language|auto`, `biasing_terms[]` (hashed/opaque dictionary hints), `mode`, `zdr:true`. No persistence.
- `POST /v1/cleanup` — body: `{transcript, mode, app_profile, style_profile_ref, verbatim:bool, context_text?(redacted), locale}` → `{text, model_tier, safety_flags}`. Streamed.
- `POST /v1/command` — body: `{selection_text, instruction, app_profile, context?}` → `{text}`. Streamed.
- `POST /v1/dictionary/sync`, `GET /v1/settings/sync` — E2E-encrypted blobs only (`{ciphertext, nonce, version}`); server is a dumb store.
- `POST /v1/account/*` — auth, plan, usage; `DELETE /v1/account` cascades deletion.
- `POST /v1/telemetry` — redacted aggregate events (opt-in).
- **Enterprise (V2):** `/v1/admin/policy`, `/v1/admin/audit`, SCIM `/scim/v2/*`, SSO via OIDC/SAML.

**Design rules:** streaming everywhere for latency; idempotency keys on non-stream calls; every request carries `zdr` + `processing_region`; strict input size limits; versioned (`/v1`); backward-compatible additions only; graceful `503`→client falls back to local. Provider-agnostic model backends behind the gateway so ASR/LLM vendors can be swapped without client changes.

**Local IPC (within client):** the native shell ↔ Rust core communicate over a typed in-process API (FFI) — not a network socket — with a stable schema for: `startCapture`, `stopCapture`, `cancel`, `onPartial`, `onFinal`, `insert(text, strategy)`, `commandTransform`, `getPrivacyStateForUtterance`. This keeps the state machine testable and platform-shells thin.

---

## 24. Database Schema

**Local store (SQLite, encrypted).** (Audio stored as encrypted blobs on disk, referenced by path/id; large blobs not in the DB row.)

```sql
-- Core dictation records
utterances(
  id TEXT PRIMARY KEY,              -- uuid
  created_at INTEGER,              -- epoch ms
  app_bundle_id TEXT,             -- target app
  mode TEXT,                       -- dictation|command|verbatim|<custom>
  processing_location TEXT,       -- 'local' | 'cloud' (actual, per utterance)
  language TEXT,
  duration_ms INTEGER,
  audio_blob_id TEXT,             -- FK to audio_blobs (nullable if audio not retained)
  transcript_instant TEXT,       -- pass 1
  transcript_final TEXT,         -- pass 2 (pre-cleanup)
  output_text TEXT,               -- inserted text (post-cleanup)
  inserted_ok INTEGER,           -- bool
  insertion_strategy TEXT,       -- direct|tsf|paste|clipboard-fallback
  redacted INTEGER,               -- bool: redaction applied
  word_count INTEGER,
  latency_ms INTEGER
);
audio_blobs(
  id TEXT PRIMARY KEY, path TEXT, bytes INTEGER, created_at INTEGER, purge_after INTEGER
);
-- Personalization
dictionary_terms(
  id TEXT PRIMARY KEY, term TEXT, normalized TEXT, casing TEXT,
  phonetic_hint TEXT, language TEXT, source TEXT,   -- manual|learned|import
  weight REAL, created_at INTEGER, last_used INTEGER, use_count INTEGER
);
corrections(
  id TEXT PRIMARY KEY, misheard TEXT, intended TEXT, app_bundle_id TEXT,
  count INTEGER, created_at INTEGER, promoted_to_dictionary INTEGER
);
style_profile(
  id INTEGER PRIMARY KEY CHECK (id=1),   -- single row
  json TEXT,                              -- learned style features
  updated_at INTEGER
);
-- Modes & rules
modes(
  id TEXT PRIMARY KEY, name TEXT, is_builtin INTEGER, prompt TEXT,
  model_tier TEXT, hotkey TEXT, verbatim INTEGER
);
app_rules(
  app_bundle_id TEXT PRIMARY KEY, enabled INTEGER, force_local INTEGER,
  force_verbatim INTEGER, default_mode TEXT, context_allowed INTEGER
);
-- Settings & privacy
settings(key TEXT PRIMARY KEY, value TEXT);   -- KV for app config
redaction_rules(id TEXT PRIMARY KEY, name TEXT, pattern TEXT, enabled INTEGER, builtin INTEGER);
-- Sync
sync_state(entity TEXT PRIMARY KEY, version INTEGER, last_synced INTEGER, dirty INTEGER);
-- Model registry
models(id TEXT PRIMARY KEY, role TEXT, version TEXT, path TEXT, hash TEXT, active INTEGER, size_bytes INTEGER);
```

**Cloud (minimal, no dictation content):** `accounts`, `subscriptions`, `devices`, `sync_blobs(user_id, entity, ciphertext, nonce, version, updated_at)`, `usage_counters(user_id, period, words, requests)`, `audit_log`(enterprise). **No table stores audio or transcripts** — the inference path is stateless/ZDR.

**Retention/purge:** a background job honors `purge_after` on `audio_blobs` and the user's history-retention window; delete is a hard delete + secure blob erase.

---

## 25. Folder Structure

Monorepo, native shells + shared Rust core.

```
cadence/
├── core/                         # shared Rust core (platform-agnostic)
│   ├── orchestrator/             # state machine (idle→listening→…)
│   ├── asr/                      # local ASR runtime bindings + streaming
│   ├── cleanup/                  # prompt assembly, local LLM runtime, hallucination guard
│   ├── dictionary/               # personal dictionary, biasing, corrections
│   ├── redaction/                # redaction filters
│   ├── store/                    # SQLite + encrypted blobs, migrations
│   ├── sync/                     # E2E encryption + sync client
│   ├── privacy/                  # per-utterance data-flow accounting
│   ├── ipc/                      # typed FFI surface for shells
│   └── models/                   # model registry, download, verify, rollback
├── platform-macos/               # Swift/AppKit shell
│   ├── Capture/ (CoreAudio)      #
│   ├── Hotkeys/ (Carbon/CGEvent) #
│   ├── Overlay/ (NSPanel HUD)    #
│   ├── Insertion/ (AX APIs)      #
│   ├── Settings/ (SwiftUI)       #
│   └── App/ (menu bar, lifecycle)#
├── platform-windows/             # C++/C# shell
│   ├── Capture/ (WASAPI)         #
│   ├── Hotkeys/ (RegisterHotKey/LL hooks)
│   ├── Overlay/ (WinUI layered topmost)
│   ├── Insertion/ (UIA/TSF/SendInput)
│   ├── Settings/ (WinUI)         #
│   └── App/ (tray, lifecycle)    #
├── cloud/                        # backend services
│   ├── gateway/                  # API gateway, auth, rate limit, routing
│   ├── asr-service/              # cloud ASR (provider-agnostic)
│   ├── llm-service/              # cleanup/instruct (provider-agnostic)
│   ├── sync-service/             # encrypted blob store
│   ├── account-service/          # auth, billing, usage
│   ├── admin-service/            # policy, audit, SCIM (V2)
│   └── infra/                    # IaC, deploy, observability
├── models/                       # model build/quantize/eval pipelines + eval sets
├── shared-protocol/              # API + IPC schema (source of truth, codegen)
├── qa/                           # test harnesses (insertion matrix, a11y, latency, WER eval)
├── docs/                         # this blueprint, ADRs, runbooks
└── tools/                        # release, signing/notarization, telemetry-redaction lint
```

---

## 26. State Management

- **Single source of truth = orchestrator state machine** in the Rust core (see §12.2). Shells subscribe to state events and render; they do not own dictation state. This guarantees mac/Win parity and makes the core unit-testable headlessly.
- **App/config state:** settings service (KV + typed structs) with change-notification; reactive UI (SwiftUI/WinUI bindings) reads a projected view model.
- **Session/ephemeral state:** current utterance context (buffer, partials, chosen strategy, processing-location decision) lives in the orchestrator and is discarded on DONE/CANCEL (except what's persisted to history).
- **Persisted state:** SQLite (dictionary, history, modes, rules, settings, sync-state, model registry).
- **Undo state:** last-insertion record (target app, inserted range, prior selection/content) kept in memory + history for the dedicated undo hotkey.
- **Concurrency rules:** only one active dictation utterance at a time; a new trigger while INSERTING queues or cancels per policy (default: ignore new PTT until DONE to avoid overlap; hands-free is continuous by design). Network calls are cancelable and tied to the utterance lifecycle.
- **Sync/CRDT:** dictionary/settings sync uses last-writer-wins per field with version vectors (`sync_state`); conflicts on dictionary are union-merged (terms rarely conflict). No cross-device real-time coordination needed.

---

## 27. Component Inventory

**Native hot-path components (per platform, driven by shared core):**
- `TriggerManager` — global hotkeys, mouse binds, modifier double-tap; conflict validation.
- `AudioCapture` — device selection, 16 kHz mono, ring buffer, level metering, hot-swap on device change.
- `VAD` — endpointing, silence trim, pause tolerance, quiet-speech gain.
- `ASRClient` — local streaming engine + cloud stream adapter; instant/refined passes; biasing injection.
- `CleanupEngine` — prompt assembly, local LLM runtime, cloud adapter, hallucination guard, verbatim path.
- `Orchestrator` — the state machine; owns utterance lifecycle, routing (local/cloud), fallback.
- `InsertionEngine` — capability detection + strategy cascade (direct API → TSF/marked-text → paste-with-clipboard-restore → notify+copy), focus/target validation, off-UI-thread with timeout, per-app overrides, single-undo-unit wrapping.
- `OverlayHUD` — non-activating window; state glyphs, live waveform, cloud/local chip, text panel; reduce-motion variants; a11y announcements.
- `PrivacyAccountant` — computes per-utterance "what left the device" and exposes it to chip + dashboard.

**Management/UI components:**
- `SettingsApp` (tabbed per §11 IA), `HistoryBrowser`, `DictionaryEditor`, `ModesEditor`, `AppRulesEditor`, `PrivacyDashboard`, `OnboardingFlow`, `PermissionsHealthCheck`, `DiagnosticsExporter`, `AccountSync`, `UsageInsights`.

**Core services (shared):**
- `LocalStore`, `SyncClient`, `RedactionService`, `DictionaryService`, `CorrectionLearner`, `StyleProfiler`, `ModelRegistry` (download/verify/rollback), `TelemetryClient` (redacted, opt-in), `Logger` (redacted).

**Cloud services:** `Gateway`, `AsrService`, `LlmService`, `SyncService`, `AccountService`, `AdminService` (V2), `TelemetrySink`.

---

## 28. Performance Targets

**Latency (stop-speaking → text settled at cursor):**
- Cloud/Hybrid: **p50 ≤ 400 ms, p95 ≤ 700 ms, p99 ≤ 1000 ms** (matches/beats Wispr's <700 ms p99 target while adding a local fallback).
- Local-only: **p50 ≤ 700 ms, p95 ≤ 1200 ms** (hardware-dependent; degrade gracefully on low-end machines).
- **Perceived start latency (key-down → capture+earcon+overlay):** ≤ 50 ms (this is what makes it feel instant).
- **Instant partial first token:** ≤ 300 ms from speech onset.
- Sub-budgets (cloud): ASR ≤ 200 ms, cleanup ≤ 200 ms, network RT ≤ 200 ms, insertion ≤ 100 ms.

**Resource (the anti-Wispr guarantee):**
- **Idle:** RAM < 150 MB, CPU < 1%, **zero network** when not dictating, models unloaded/lazy after inactivity.
- **Active dictation (local):** RAM peak < 1.2 GB with local models loaded (configurable to a "lite" model for low-RAM machines); CPU bounded; **never** freeze or block the target app (insertion timeout ≤ 250 ms then fallback).
- **Battery:** no measurable drain at idle; efficient capture; suspend models on sleep.
- **Startup:** cold launch to ready < 2 s; first dictation available immediately (bundled local model).
- **Insertion reliability:** ≥ 98% success across top-100 apps; **0 clipboard-corruption** incidents; **0 target-app freezes** (hard requirement — regression = release blocker).

**Accuracy targets (measured on internal eval sets, §30):**
- Match or beat the best reported competitor (Aqua-class) on **email** and **technical/code** dictation WER; beat Apple Dictation on names/jargon by a wide margin. Publish methodology; never cite a number we can't reproduce.

**Availability:** local path 100% (offline). Cloud path target 99.9%+; cloud outage must be invisible (auto-fallback).

---

## 29. Error Handling Strategy

**Philosophy (P6):** fail soft, never silent, words always recoverable. Every failure has a defined fallback and an honest, actionable message.

| Failure | Detection | Fallback | User-visible |
|---|---|---|---|
| Network loss / cloud timeout | RPC timeout/health | Local pipeline for this utterance | Indicator flips to "Offline — on-device"; no error modal |
| Cloud 5xx / rate limit | HTTP status | Local fallback + retry-later for cloud tier | Subtle "using on-device" chip |
| ASR returns empty (silence) | empty final | No insertion | "Didn't catch that" gentle earcon+chip |
| Cleanup model drift/hallucination | hallucination guard | Insert lightly-cleaned verbatim | (silent; logged) |
| Insertion target lost focus / unfocusable | focus check pre-insert | Copy to clipboard (restore prior after) + toast | "Copied — press ⌘V to paste" |
| Insertion API blocked (sandboxed/secure field) | strategy failure | Next strategy in cascade; final = clipboard | Toast if fell to clipboard |
| Target app freeze risk (slow AX/UIA) | insertion timeout ≤250ms | Abort → clipboard fallback | Toast; log app for per-app override |
| Model missing/corrupt | hash verify fail | Roll back to bundled golden model | "Restored a working model" notice |
| Mic unavailable/permission lost | device error | Halt capture; guide re-grant | Clear re-grant flow |
| Crash mid-utterance | ring buffer + WAL history | Recover audio+partial on relaunch; offer re-insert | "Recovered your last dictation" |
| Command Mode: no/unreadable selection | AX/UIA read fail | Prompt to select / clipboard-read fallback | "Select text first" |
| Sync conflict | version vector | Union/LWW merge | (silent; visible in history if needed) |
| Redaction uncertain | pattern match | Prefer to redact; if cloud, block send & note | "Sensitive content kept on-device" |

**Cross-cutting:** structured, **redacted** logging (never log transcript/audio content by default); opt-in diagnostics bundle for support; global "something went wrong but your text is safe here" recovery panel that always shows the last N utterances' text.

---

## 30. Testing Strategy

- **Unit (core, headless):** orchestrator state machine (all transitions, cancellations, fallbacks), redaction filters (precision/recall on labeled patterns), dictionary/biasing, prompt assembly (golden templates), hallucination guard, storage/migrations, sync merge logic. High coverage on the Rust core because it's platform-agnostic and testable without UI.
- **ASR/cleanup quality (offline eval harness):** curated eval sets per domain (email, chat, code/technical, names, multilingual, code-switching, noisy, whispered) with reference transcripts; track WER + a formatting-quality metric (human + model-graded) + tone-appropriateness; regression gate on model updates; A/B rollout with client-side rollback.
- **Insertion matrix (the differentiator test):** automated + manual suite across the **top-100 target apps** (browsers, Slack/Teams, VS Code/Cursor/JetBrains, terminals iTerm2/Terminal/Windows Terminal, Office, Google Docs/Notion in-browser, Electron apps, password fields, native mac/Win text fields, RTL fields). Assert: correct insertion, **no clipboard corruption**, **no target freeze** (timeout enforced), correct undo. Run per-release; failures are release blockers.
- **Latency benchmarks:** automated harness measuring perceived-start, first-partial, and end-to-end p50/p95/p99 on a device matrix (low/mid/high-end mac + Win); gate against §28 budgets.
- **Resource tests:** idle RAM/CPU/network over 24 h; active peak; leak detection; battery; assert §28 budgets (idle <150 MB etc.).
- **Reliability/soak:** long hands-free sessions; network flapping (loss/restore mid-utterance); repeated crash-recovery; verify "no lost words" invariant.
- **Privacy/security tests:** network-egress assertion in Local-only mode (**must be zero packets**); redaction efficacy; no-screenshot verification; ZDR verification (no server persistence); pen-test; dependency/SBOM scan; signed-model tamper test.
- **Accessibility tests (release gate):** VoiceOver/Narrator/NVDA flows, keyboard-only, 200% zoom, high-contrast, reduce-motion, RTL, screen-reader announcement correctness for overlay states.
- **Localization tests:** command grammar per locale; RTL layout; multilingual/code-switch accuracy.
- **Onboarding funnel test:** first-dictation-in-60s success rate; permission-grant completion.
- **Beta program:** dogfood + external beta with opt-in redacted telemetry to find real-world insertion/latency edge cases and to empirically choose default hotkeys and pause thresholds.

---

## 31. Acceptance Criteria (per feature)

Format: **Given / When / Then**, testable. (IDs match §7.)

- **AC-1 (F1 PTT):** Given any focused text field, when the user holds the PTT hotkey and speaks and releases, then polished text appears at the cursor within the §28 latency budget, and audio capture began within 50 ms of key-down (verified by earcon+overlay).
- **AC-2 (F2 Hands-free):** Given hands-free toggle, when the user taps to start, speaks multiple paragraphs with natural pauses, and taps to stop, then no pause under the configured threshold ends the session and text is inserted incrementally without loss.
- **AC-3 (F3 Continuous):** Given continuous mode enabled, then a persistent unmissable LISTENING indicator is shown in the user's chosen modality and an auto-timeout (configurable) exists; the mic is never hot without indication.
- **AC-4 (F4 Triggers):** Given the settings, when a user binds a keyboard/mouse trigger that conflicts with an OS reservation, then the app rejects it with an explanation; valid binds work globally across apps.
- **AC-5 (F5 Instant-start):** Given a cold model state, when the user starts speaking immediately on key-down, then no leading audio is lost (ring buffer) and the first words are transcribed.
- **AC-6 (F6 Cancel):** Given an active utterance, when the user presses Esc, then nothing is inserted, the buffer is cleared, and the overlay returns to idle.
- **AC-7 (F7 Two-pass):** Given streaming enabled, then an instant partial is visible ≤300 ms after speech onset and a refined version settles per the chosen insertion strategy without flicker beyond the defined settle animation.
- **AC-8 (F8 Cleanup):** Given a spoken utterance with fillers/run-ons, then the output has fillers removed, correct punctuation/casing, and detected structure (lists) — while preserving meaning (hallucination guard passes).
- **AC-9 (F9 Context format):** Given dictation into Slack vs email vs a doc, then tone/format differ per app profile (e.g., casual vs formal) as configured.
- **AC-10 (F10 Context biasing):** Given on-screen context is opt-in ON and passes redaction, then ambiguous names/terms near the cursor are transcribed correctly at a higher rate than with it off (measured); given Local-only, no context leaves the device.
- **AC-11 (F11 Dictionary):** Given a term in the personal dictionary, then it is transcribed with correct spelling/casing; a newly added term takes effect on the next utterance without restart.
- **AC-12 (F12 Correction learning):** Given the user corrects a misheard term post-insert (learning ON), then the app offers to learn it and, once learned, does not repeat the error on subsequent utterances.
- **AC-13 (F13 Multilingual):** Given supported languages, then auto-detection selects the right language and an in-utterance switch between two supported languages is transcribed correctly for the top language pairs.
- **AC-14 (F14 Whisper):** Given quiet/whispered speech in the supported range, then transcription succeeds at a defined accuracy floor without the user raising their voice.
- **AC-15 (F15 Verbatim):** Given verbatim mode, then no semantic changes or filler removal occur; the literal transcript is inserted; the literal words are always recoverable from history.
- **AC-16 (F16 Command Mode):** Given selected text and a spoken instruction, then the selection is replaced by the transformed text, the original is preserved for undo, and if no selection exists the user is prompted appropriately.
- **AC-17 (F17 Inline commands):** Given inline command phrases during dictation, then "new paragraph/scratch that/bullet" etc. are executed, with the content-vs-command ambiguity resolved per policy.
- **AC-18 (F18 Custom modes):** Given a user-created mode with its own prompt/model/hotkey/auto-activate rule, then triggering it (or entering the mapped app) applies that mode's behavior.
- **AC-19 (F19 Snippets):** Given a voice snippet trigger, then the mapped expansion is inserted. [V2]
- **AC-20 (F20 Insertion):** Given the top-100 app matrix, then insertion succeeds ≥98% with **zero clipboard corruption** and **zero target freezes**; when only clipboard works, prior clipboard contents are restored and the user is notified.
- **AC-21 (F21 Undo):** Given an insertion, when the user invokes undo (native ⌘Z where supported, or the dedicated hotkey), then exactly the inserted range is reverted, restoring the prior field state.
- **AC-22 (F22 History/recovery):** Given a crash or network loss mid-utterance, on relaunch the last utterance's audio+transcript are recoverable and re-insertable; history is searchable and per-item deletable.
- **AC-23 (F23 Offline):** Given no network, then full dictation (ASR+cleanup+insertion) works on-device and the offline indicator is shown; no feature that claims offline requires network.
- **AC-24 (F24 Degradation):** Given a cloud failure mid-utterance, then the utterance completes via local fallback with no user action and the per-utterance indicator shows "local."
- **AC-25 (F25 Data-flow indicator):** Given any utterance, then the chip accurately reflects whether audio/text left the device for *that* utterance; the Privacy dashboard enumerates exactly what is sent when cloud is used.
- **AC-26 (F26 ZDR):** Given the cloud path, then no audio/transcript is persisted server-side by default (verified by test/audit); training on user data is off unless explicitly opted in.
- **AC-27 (F27 Per-app rules):** Given a per-app rule (disable/force-local/verbatim/default-mode), then it overrides global policy for that app; password managers are disabled by default.
- **AC-28 (F28 Redaction):** Given redaction rules, then matching patterns are stripped before any cloud send and before storage; in ambiguous cases the system errs toward redaction and keeps content local.
- **AC-29 (F29 No dark patterns):** Given a fresh install, then launch-at-login is OFF; permissions are requested with rationale only when needed; uninstall removes login items, models, and local data (after an offered export).
- **AC-30 (F30 Style):** Given repeated dictation, then learned style (punctuation/tone/closings) is reflected in output and is user-viewable/resettable; all local.
- **AC-31 (F31 Sync):** Given sync ON, then dictionary/settings/style replicate across the user's devices as ciphertext only (server cannot read plaintext); conflicts merge without data loss.
- **AC-32 (F32 Insights):** Given usage, then local-only stats (words, time saved, accuracy trend) are shown; nothing is uploaded unless telemetry is opted in.
- **AC-33–35 (Enterprise):** [V2] SSO/SCIM provisioning works; policies (force-local/blocklist/retention) are enforced on managed devices; audit log records admin-relevant events; SOC 2 Type II + HIPAA BAA available.
- **AC-36 (F36 Surface):** Given the app runs, then it presents a menu-bar/tray control and a non-activating overlay that never steals focus from the target field.
- **AC-37 (F37 Onboarding):** Given first run, then ≥ (target) % of users complete a successful real dictation within 60 s; permissions are explained in plain language; a failed permission has a clear recovery path.
- **AC-38 (F38 Mobile):** [V2] iOS/Android keyboard+dictation reach parity on core dictation.

---

## 32. Engineering Roadmap & Implementation Order

**Sequencing principle:** build the reliability/latency spine first (the thing competitors get wrong), then quality, then breadth. Never ship a version that can lose a user's words or freeze an app.

### Phase 0 — Foundations & spikes (pre-alpha)
- Shared **protocol/IPC schema** + **orchestrator state machine** (headless, fully tested).
- **Insertion engine spikes on both OSes** across the hardest apps (terminals, VS Code/Electron, password fields) — *prove* the no-freeze/no-clipboard-corruption approach before building on it. **This is the highest-risk item; validate first.**
- Local ASR + local cleanup model integration spike (latency + resource on a device matrix).
- Bundled "golden" local models chosen; model registry + signing.
**Exit criteria:** a headless core that transcribes a WAV → cleaned text; an insertion prototype passing a 20-app subset with zero freezes/corruption.

### Phase 1 — MVP (local-first core)
Deliver: F1 PTT, F5 instant-start, F6 cancel, F7 two-pass (local), F8 cleanup (local), F15 verbatim, F20 insertion engine, F21 undo, F22 history/recovery, F23 offline, F24 degradation (local baseline), F25 data-flow indicator, F26 ZDR (n/a offline), F27 per-app rules, F29 no-dark-patterns, F36 surface, F37 onboarding, core Privacy dashboard, F11 dictionary (manual). Global hotkeys (F4 core).
**Exit:** the full offline loop is delightful and reliable; insertion matrix (top-50) passes; latency/resource budgets met on mid-tier hardware; onboarding <60 s.

### Phase 2 — Cloud tier & quality (Pro)
Add: cloud ASR + cloud cleanup (Hybrid/Cloud-preferred), F9 context formatting/app profiles, F16 Command Mode, F2 hands-free, account/billing, F31 sync (E2E), redaction filters (F28), telemetry (opt-in). Latency budgets for cloud; ZDR verified.
**Exit:** cloud quality beats local measurably on eval sets; Command Mode robust; sync works; ZDR audited.

### Phase 3 — Intelligence & breadth
Add: F10 on-screen context biasing (opt-in), F12 correction learning, F13 full multilingual + code-switching, F14 whisper, F17 inline commands, F18 custom modes, F30 style profile, F32 insights, F3 continuous mode + a11y hardening.
**Exit:** accuracy on hard content matches/beats best competitor; a11y release gates pass.

### Phase 4 — Enterprise & scale (V2 start)
Add: F33 team/SSO/SCIM, F34 policy/DLP/audit, F35 SOC 2 Type II + HIPAA BAA, data residency, admin console.

### Phase 5 — Mobile & ecosystem (V2)
Add: F38 iOS/Android, launcher extensions (Raycast/Alfred/PowerToys), file-transcription bridge (§34).

**Critical path / dependencies:** Insertion engine → everything (Phase 0 gate). Orchestrator → all pipeline features. Local models → offline claim. ZDR/redaction → cloud tier & enterprise. Sync → multi-device & style. A11y is continuous, not a phase (built in, gated per release).

**Team shape (suggested):** core/Rust (2–3), macOS (2), Windows (2), ML/models+eval (2–3), cloud/infra (2), design (1–2), QA/insertion-matrix+a11y (2). Insertion and ML are the scarce skills — staff them first.

**Milestone gates (every release):** insertion matrix green (0 freezes/0 corruption), latency budgets met, resource budgets met, a11y matrix green, privacy egress test green (0 packets in Local-only), no P0/P1 open.

---

## 33. Self-Critique Log (issues found → resolved)

Per the mission, after drafting I audited the blueprint as a Principal Engineer + Head of Product preparing for launch, across two passes. Below are the issues found and how each was resolved *in this document*. (≥20 required; 28 logged.)

**Pass 1 — structural & requirement gaps**
1. *Two-pass insertion could corrupt the user's edits* if pass-2 replaces text the user already modified. → Added the **two-pass insertion contract** (§12.3) with user-interference detection and "never corrupt the document" precedence.
2. *"Insert instantly then replace" vs "wait and insert once" was unspecified* — a real Wispr/Aqua UX fork. → Specified both strategies A/B, defaults, and when each applies (§12.3).
3. *No-lost-words was a slogan without mechanism.* → Added ring buffer + WAL history + crash recovery flow + AC-22 (§11 P3, §18, §29).
4. *Offline claim was vague on first-run.* → Mandated a **bundled golden local model** so offline works before any download (§17.5, §32 Phase 0).
5. *Insertion "freeze the app" risk (Wispr's real bug) wasn't engineered against.* → Off-UI-thread insertion with a ≤250 ms timeout + fallback; made "0 freezes" a release-blocking gate (§16.3, §28, §30).
6. *Clipboard corruption from paste-based insertion.* → Clipboard **save/restore** + prefer direct APIs; AC-20 asserts zero corruption (§12.3, §20, §27).
7. *Privacy indicator ambiguity:* the chip could show the *policy* not the *actual* path. → Defined **per-utterance truth** — chip reflects what actually happened, incl. degraded fallbacks (§19, §12.2, AC-25).
8. *On-screen context = Wispr's screenshot scandal risk.* → Explicitly **no screenshots**, structured-text-only, opt-in, redaction-filtered, never in Local-only (§20, §22, AC-10).
9. *Latency budget lacked "perceived start."* → Added ≤50 ms key-down→capture+earcon+overlay as its own target (§28) — this is what actually makes it feel instant.
10. *Cleanup LLM hallucination risk* (inventing content in dictation). → Added **hallucination guard** + verbatim fallback (§17.2, §29).

**Pass 2 — engineering, security, UX, a11y, edge cases**
11. *Electron vs native was hand-waved.* → Committed to native hot path + shared **Rust core**, with explicit tradeoff and mitigation (§16.2).
12. *Model crash could kill the hotkey listener.* → Separate helper process for inference so capture/trigger survive model crashes (§16.3).
13. *Concurrency (new dictation during insertion) undefined.* → Defined single-utterance concurrency policy + cancelable network calls (§26).
14. *Undo across arbitrary apps is hard* (native ⌘Z may not cover our insertion). → Wrap insertion as a single undo unit where possible **and** provide a dedicated global undo hotkey + history re-insert (§12.4, §26, AC-21).
15. *Sandbox/entitlement conflict with system-wide injection* unaddressed (Apple has rejected AX-injection apps). → Called out the entitlement tension, least-privilege stance, and App Store vs direct-distribution consideration (§21). (Note for Fable: direct notarized distribution likely required; document entitlement rationale.)
16. *Security threat model was missing.* → Added explicit threat model + mitigations (§21) and privacy/egress tests (§30).
17. *Local-only "no data leaves" needs proof, not promise.* → Added a **network-egress test asserting zero packets** in Local-only as a release gate (§30, AC-23/26).
18. *Password fields / secure input* could be silently captured or broken. → Default per-app disable for password managers + secure-field handling + AC-27 (§20, §7 F27).
19. *Accessibility of continuous mode's own safeguards* (a blind user must perceive "listening"). → Required indicators in the user's modality + earcon/visual equivalence (§12.6, §15, AC-3).
20. *Reduce-motion users* got a waveform-heavy design. → Defined reduce-motion variants for every animation and the overlay (§13, §15).
21. *Multilingual command grammar & RTL* were English-centric. → Localized command grammar + RTL overlay/settings + localization tests (§12.5, §15, §30).
22. *Accuracy claims risked citing unverifiable competitor numbers as fact.* → Reframed all competitor metrics as *reported*, and committed to publishing reproducible internal eval methodology rather than marketing numbers (§8, §28, §30).
23. *"Time saved" insight could feel like a dark pattern / inflate value.* → Kept insights **local-only**, honest, opt-in for any upload (§7 F32, §20, AC-32).
24. *Cost model for cloud unbounded.* → Rate limiting, usage counters, local fallback on quota; local tier is free and always available (§19, §21, §23).
25. *No spec for what happens when the caret location is unknown* (overlay placement). → Fallback to a fixed user-chosen anchor; never cover the caret (§12.1).
26. *Model update could regress quality silently.* → Versioned models, A/B rollout, **client-side rollback**, eval regression gate (§17.5, §30).
27. *Redaction false-negatives* could leak secrets to cloud. → Err toward redaction; block cloud send + keep local when uncertain; AC-28 (§20, §29).
28. *Roadmap risk ordering:* quality-first would build atop an unproven insertion layer. → Reordered so **insertion + no-lost-words spine is Phase 0/1**, quality later; insertion is the explicit highest-risk Phase-0 gate (§32).

**Residual risks (honestly disclosed, for Fable to watch):**
- OS-vendor platform risk (Apple/Microsoft could ship a comparable ambient dictation layer). Mitigation: privacy/offline/accuracy differentiation + cross-platform + speed of iteration.
- Insertion is an eternal cat-and-mouse with app updates; budget ongoing maintenance of the per-app matrix.
- On-device model quality on low-end hardware may force a "lite" tier; set expectations in onboarding by detecting hardware.
- Default hotkey choice will conflict for *someone*; ship presets + easy rebind + conflict detection, and finalize defaults from beta data.

After Pass 2, no remaining issue rose to "major weakness" that blocks a senior team from implementing; open items are operational risks with named mitigations, not spec gaps.

---

## 34. Version 2 Opportunities

- **Mobile (iOS/Android):** custom keyboard + system dictation; on-device where the platform allows; shared core.
- **Meeting/file transcription bridge:** a MacWhisper-class batch mode (drop a file / capture system audio) reusing the ASR stack — different job, shared infra, natural upsell. Requires clear consent/recording law handling.
- **Launcher/ecosystem extensions:** Raycast, Alfred, PowerToys Run, Spotlight-adjacent — meet power users where they are.
- **"Ask" command (bounded generation):** an explicit, clearly-labeled mode that *generates* (not just transcribes) — "draft a reply saying we'll ship Friday" — using the cloud LLM, distinct from dictation so we never blur the "just insert my words" trust boundary.
- **Team style/dictionary sharing:** shared org dictionaries (product names, people), shared modes, with admin governance.
- **Deeper accessibility:** full voice *navigation/control* (Windows-Voice-Access-class) layered on Cadence dictation for the motor-accessibility persona.
- **On-device fine-tuning / personal adapters:** per-user LoRA-style adapters for ASR/cleanup, trained locally, for step-change personalization without cloud training.
- **Developer mode:** repo-aware dictionary (symbols/APIs), code-comment/docstring modes, commit-message mode, terminal-command mode with safety confirmation.
- **Real-time translation dictation:** speak language A, insert language B.
- **API/SDK:** let other apps embed Cadence dictation as a first-class input.

---

## 35. Appendices

### 35.1 Glossary
- **ASR** — automatic speech recognition (speech→text).
- **Cleanup/instruct model** — LLM that formats a transcript / performs a voice-commanded transformation.
- **Two-pass (Instant/Refined)** — fast partial shown immediately, accurate final settled after.
- **Context conditioning / biasing** — improving ASR by conditioning on dictionary, history, app, and (opt-in) on-screen text.
- **ZDR** — zero data retention (no server-side persistence of audio/transcripts).
- **Insertion engine** — the component that places text into the target app via AX/UIA/TSF/clipboard.
- **Overlay/HUD** — the transient, non-activating on-screen state indicator.
- **VAD** — voice activity detection / endpointing.
- **PTT** — push-to-talk.

### 35.2 Source notes (research provenance, treat competitor metrics as *reported*, not verified)
- Wispr Flow: official site/docs/features/why-flow/pricing; Baseten case study (fine-tuned Llama, TensorRT-LLM, Chains, <700 ms p99, ~200 ms sub-budgets, ~1B words/mo); "technical challenges" engineering post (context-conditioned ASR, personalized cleanup, local correction learning); third-party reviews (Spokenly, eesel, getvoibe, letterly, tldv, weesper, willowvoice); Wispr roadmap/changelog (Command Mode beta); Wispr help center (hotkeys, Command Mode). Reddit/Trustpilot complaints: reliability-after-trial, ~800 MB/8% idle on Windows + app freezes, screenshot/context capture, auto-launch/login-item behavior, training-data defaults (later opt-in), Trustpilot ~2.7 vs G2 ~4.5.
- Superwhisper: official site/docs/changelog + reviews — local Whisper + Parakeet models, offline realtime (Parakeet Realtime), Super Mode (context-aware), unlimited custom modes (per-mode prompt/model/hotkey/auto-activate), lifetime pricing, 100+ languages.
- Aqua Voice: official site + reviews/YC — fusion transcription + client context engine, sub-2% WER claims on email/technical vs Wispr ~10%, Instant (~450 ms) vs Streaming (~850 ms), natural-language editing, Mac/Win, cloud.
- MacWhisper: file transcription, local Whisper, simple, one-time price.
- Raycast dictation: cloud, hosted GPT-class cleanup, no local LLM in beta, tied to Raycast.
- Apple Dictation: on-device on Apple Silicon (~96% quiet), verbatim, breaks in terminals/Electron/secure fields.
- Windows Voice Access: on-device, verbatim, strong voice control/navigation, accessibility-focused.
- Text-injection mechanics: cascade of clipboard-paste / Accessibility API / keystroke simulation; terminals & Electron & secure fields are the hard cases; Apple has rejected AX-injection apps not framed as accessibility.

> **Provenance caveat for Fable:** all quantitative competitor claims above are drawn from public marketing and third-party reviews as of mid-2026 and may be inaccurate or self-serving. Do **not** hard-code product decisions to any single number; validate against your own eval harness (§30). Cadence's targets are set to *match or beat the best credible competitor* on each axis, with reproducible internal measurement as the source of truth.

---

*End of blueprint. This document is intended to be sufficient for a senior team (or Fable) to implement Cadence without further clarification. Where judgment calls remain (default hotkey, exact local model, precise pause thresholds), the document specifies how to decide (beta data, eval harness) rather than leaving them open.*
