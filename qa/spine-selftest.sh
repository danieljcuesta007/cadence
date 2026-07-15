#!/bin/zsh
# Phase-1 spine E2E: WAV → FFI ring → whisper → cleanup → REAL insertion into TextEdit.
# Exercises the exact shell pipeline minus the microphone (see `cadence selftest-wav`).
#
# Safety: the selftest binary refuses to insert unless TextEdit is frontmost (built-in,
# non-optional guard). If the user takes the keyboard back mid-run, the run degrades to
# clipboard-notify and this script reports FAIL — it never types at their focus.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/platform-macos/.build/release/cadence"
CTL="$ROOT/platform-macos/.build/debug/insertctl"
WAV="${1:-$ROOT/qa/fixtures/hello.wav}"

[[ -x "$BIN" ]] || { echo "build first: qa/build-shell.sh" >&2; exit 1; }

TEXTEDIT_WAS_RUNNING=0
pgrep -xq TextEdit && TEXTEDIT_WAS_RUNNING=1

DOC=$(mktemp /tmp/cadence-spine-XXXX).txt
: > "$DOC"
open -a TextEdit "$DOC"
sleep 2

FRONT=$("$CTL" frontmost)
if [[ "$FRONT" != "TextEdit" ]]; then
    echo "SKIP: could not bring TextEdit frontmost (frontmost=$FRONT)" >&2
    exit 1
fi

# Sentinel proves clipboard restoration through the real cascade.
printf '%s' "spine-sentinel" | pbcopy

OUT=$("$BIN" selftest-wav "$WAV" --expect-app TextEdit 2>/tmp/cadence-spine-stderr.log)
STATUS=$?
READBACK=$("$CTL" read 2>/dev/null)
CLIP=$(pbpaste)

echo "$OUT"
echo "readback: $(echo "$READBACK" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("value") or "")[:120])')"
echo "clipboard_restored: $([[ "$CLIP" == "spine-sentinel" ]] && echo true || echo false)"
grep -E "insertion:|capture|refused" /tmp/cadence-spine-stderr.log || true

# Leave no test window behind if we started TextEdit ourselves.
if [[ $TEXTEDIT_WAS_RUNNING -eq 0 ]]; then
    pkill -x TextEdit
fi
rm -f "$DOC"
exit $STATUS
