#!/bin/zsh
# Semi-automated Phase-0 insertion matrix (see INSERTION_MATRIX.md).
# For each target you focus, this runs the cascade, then verifies the clipboard was restored
# and reports strategy + latency. Apps #17/#18 must REFUSE (secure fields).
#
# Usage:
#   qa/insertion-matrix.sh              # interactive: prompts you to focus each target
#   qa/insertion-matrix.sh --one "Name" # single probe against whatever you focus
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CTL="$ROOT/platform-macos/.build/debug/insertctl"

if [[ ! -x "$CTL" ]]; then
    echo "build first: (cd platform-macos && swift build)" >&2
    exit 1
fi

# Gate 0: engine self-test must pass before touching any real app.
if ! "$CTL" selftest | grep -q '"pass" : true'; then
    echo "FAIL: insertctl selftest failed — fix the engine before running the matrix" >&2
    exit 1
fi

if ! "$CTL" check | grep -q '"axTrusted" : true'; then
    echo "Accessibility not granted to this terminal." >&2
    echo "System Settings → Privacy & Security → Accessibility → enable this terminal, then rerun." >&2
    exit 1
fi

PAYLOAD="cadence matrix $(date +%s)"
SENTINEL="matrix-sentinel-$(date +%s)"

probe() {
    local name="$1"
    # Seed a sentinel so clipboard restoration is verifiable.
    printf '%s' "$SENTINEL" | pbcopy
    echo ""
    echo ">>> [$name] focus the target field now — inserting in 5s..."
    local t0=$(date +%s%N 2>/dev/null || python3 -c 'import time;print(int(time.time()*1e9))')
    local out
    out=$("$CTL" insert "$PAYLOAD" --delay 5 2>/dev/null)
    local code=$?
    local t1=$(date +%s%N 2>/dev/null || python3 -c 'import time;print(int(time.time()*1e9))')
    local strategy=$(echo "$out" | grep '"strategy"' | cut -d'"' -f4)
    local elapsed=$(echo "$out" | grep '"elapsedMs"' | grep -o '[0-9]*')
    local refused=$(echo "$out" | grep '"refusedSecureField" : true' >/dev/null && echo yes || echo no)
    local clip="$(pbpaste)"
    local restored="no"
    [[ "$clip" == "$SENTINEL" ]] && restored="yes"
    local freeze="no"
    [[ -n "$elapsed" && "$elapsed" -gt 1500 ]] && freeze="SUSPECT"
    printf '%-28s inserted=%s strategy=%-16s refused=%s clipboard_restored=%s engine_ms=%s freeze=%s\n' \
        "$name" "$([[ $code -eq 0 ]] && echo yes || echo no)" "$strategy" "$refused" "$restored" "${elapsed:-?}" "$freeze"
}

if [[ "${1:-}" == "--one" ]]; then
    probe "${2:-manual}"
    exit 0
fi

APPS=(
    "Terminal" "iTerm2" "VS Code" "Cursor" "Slack" "Discord" "TextEdit" "Notes"
    "Safari (Gmail)" "Chrome (Docs)" "Chrome (textarea)" "Mail" "Messages" "Xcode"
    "Finder rename" "Spotlight" "Safari password field (MUST REFUSE)"
    "1Password (MUST REFUSE)" "Pages/Word" "JetBrains"
)
echo "Phase-0 insertion matrix — ${#APPS[@]} targets. Payload: \"$PAYLOAD\""
for app in "${APPS[@]}"; do
    probe "$app"
done
echo ""
echo "Done. Verify in each app that the payload text landed (and ⌘Z removes it)."
