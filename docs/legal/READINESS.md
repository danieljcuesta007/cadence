# Before Cadence is sold or widely promoted

Researched 13 Oct 2026 by Claude for Daniel. Not legal advice; take it to the ND IDEA
Center (free) or a startup lawyer before charging money.

## Done

- **Naming competitors:** the site names Wispr Flow, Superwhisper and Apple Dictation only
  in a dated, sourced comparison, uses no logos or their styling, says where they win, and
  states Cadence is not affiliated. Tests fail if the date, sources or disclaimer go.
- **Whisper and friends:** Whisper (MIT), whisper.cpp (MIT), whisper-rs (Unlicense),
  rusqlite (MIT), SQLCipher (BSD-style), OpenSSL (Apache 2.0). All allow commercial use.
  Their full texts are in `THIRD_PARTY_NOTICES.md`, which now ships inside the app and the
  disk image (Apache 2.0 requires the notice to travel with copies).
- **Privacy:** `site/legal.html#privacy` (no network, `~/.cadence` encrypted, audio off by
  default; site has no cookies or analytics).
- **Not notarized, explained:** the site says plainly that skipping Apple's $99/year
  program keeps Cadence free, and walks through Open Anyway.

## Open: Daniel's decisions

1. **The name is the real risk.** Cadence Design Systems owns CADENCE for computer
   software (US Reg. No. 2025016, class 9, chip-design software) and enforces a large
   portfolio. Different goods, but software-on-software with an identical word mark is the
   kind of overlap that draws a letter. Before selling or advertising, get a clearance
   opinion, or consider a distinct name (for example "Cadence Dictation" is still risky; an
   unrelated coined word is safest). Giving it away free on GitHub is lower risk.
2. **Notre Dame IP policy** (2021, §3): applies to students using University resources;
   ND claims work made with *Substantial Use* of them. Own Mac, own time: very likely yours.
   Confirm with the IDEA Center whether the Claude plan used to build it is ND-paid, and that
   Cadence was never coursework or ND-funded.
3. **Getting paid** (only if selling): merchant of record (Lemon Squeezy / Paddle) for
   sales tax; an LLC to separate it from you. If you charge, notarizing ($99/yr) becomes
   worth it, and the "why it isn't notarized" copy changes.

## Release checklist

1. `qa/package-app.sh` then `qa/make-dmg.sh 0.1.0` (asset must stay named `Cadence.dmg`).
2. Tag, push, `gh release create v0.1.0 dist/Cadence.dmg`.
3. PR the cask + site checksum; deploy the site to Cloudflare Pages project
   `cadence-dictation` (free name as of 13 Oct 2026).
4. Download it on another account and walk through Open Anyway once.
