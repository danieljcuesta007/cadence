#!/bin/zsh
# Idle resource soak for the installed Cadence.app (§28 budget: <150 MB / <1% CPU / 0 network).
# Samples phys footprint (top MEM = what Activity Monitor shows), RSS, cumulative CPU time,
# thread count, and open sockets. One JSON line per sample.
#
# Usage: qa/soak.sh [interval_s] [duration_s] [out.jsonl]
set -u
INTERVAL="${1:-30}"
DURATION="${2:-1800}"
OUT="${3:-$(dirname "$0")/soak-results.jsonl}"

PID=$(pgrep -f "Cadence.app/Contents/MacOS" | head -1)
[[ -n "$PID" ]] || { echo "Cadence.app not running" >&2; exit 1; }

END=$(( $(date +%s) + DURATION ))
while (( $(date +%s) < END )); do
    ps -p "$PID" >/dev/null 2>&1 || { echo "{\"ts\":\"$(date -u +%FT%TZ)\",\"error\":\"process_exited\"}" >> "$OUT"; exit 1; }
    TOPLINE=$(top -l 1 -pid "$PID" -stats mem,cmprs,th 2>/dev/null | tail -1)
    MEM=$(echo "$TOPLINE" | awk '{print $1}')
    CMPRS=$(echo "$TOPLINE" | awk '{print $2}')
    TH=$(echo "$TOPLINE" | awk '{print $3}')
    RSS_KB=$(ps -o rss= -p "$PID" | tr -d ' ')
    CPUTIME=$(ps -o time= -p "$PID" | tr -d ' ')
    SOCKETS=$(lsof -a -i -p "$PID" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
    echo "{\"ts\":\"$(date -u +%FT%TZ)\",\"pid\":$PID,\"footprint\":\"$MEM\",\"cmprs\":\"$CMPRS\",\"rss_kb\":$RSS_KB,\"cputime\":\"$CPUTIME\",\"threads\":$TH,\"sockets\":$SOCKETS}" >> "$OUT"
    sleep "$INTERVAL"
done
echo "soak complete: $OUT" >&2
