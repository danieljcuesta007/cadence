# Insertion matrix — Phase-0 20-app subset (§30, §32)

Gate: **zero freezes, zero clipboard corruption** across the subset; ≥98% insertion success.
Full top-100 matrix is a Phase-1 release gate.

## Prerequisite (one-time, user action)

Grant **Accessibility** to the terminal that runs the harness:
System Settings → Privacy & Security → Accessibility → enable your terminal app.
Verify with: `platform-macos/.build/debug/insertctl check` → `"axTrusted": true`.

## Phase-0 subset (hardest-first, per §32)

| # | App | Class | Expected strategy |
|---|-----|-------|-------------------|
| 1 | Terminal.app | terminal | pasteRestore |
| 2 | iTerm2 | terminal | pasteRestore |
| 3 | VS Code | Electron editor | pasteRestore (AX weak) |
| 4 | Cursor | Electron editor | pasteRestore |
| 5 | Slack | Electron | pasteRestore |
| 6 | Discord | Electron | pasteRestore |
| 7 | TextEdit | native NSTextView | direct |
| 8 | Notes | native | direct |
| 9 | Safari (Gmail compose) | web contenteditable | direct/pasteRestore |
| 10 | Chrome (Google Docs) | web canvas-ish | pasteRestore |
| 11 | Chrome (plain textarea) | web | direct/pasteRestore |
| 12 | Mail compose | native | direct |
| 13 | Messages | native | direct |
| 14 | Xcode / CLT editor | native custom | direct/pasteRestore |
| 15 | Finder rename field | native small field | direct |
| 16 | Spotlight | non-activating panel | pasteRestore |
| 17 | Safari password field | secure field | **refuse** (refusedSecureField) |
| 18 | 1Password / Keychain prompt | secure input | **refuse** (secureEventInput) |
| 19 | Word or Pages | document editor | direct/pasteRestore |
| 20 | JetBrains IDE (any) | JVM custom widget | pasteRestore |

Pass criteria per app:
1. `inserted: true` (or a correct **refusal** for #17–18);
2. text verifiably present in the target field;
3. `pbpaste` unchanged after the run (clipboard restored);
4. target app responsive during + after (no beachball — the harness times the call: > 1.5 s = fail);
5. undo (⌘Z) removes the inserted text where the app supports undo.

Record results in the table printed by `qa/insertion-matrix.sh` and paste into docs/STATUS.md.
