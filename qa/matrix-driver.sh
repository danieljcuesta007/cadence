# Sourced helper for the automated insertion matrix. Requires Accessibility on the host shell.
CTL=~/cadence/platform-macos/.build/debug/insertctl
R=~/cadence/qa/matrix-results.jsonl

test_app() { # $1 = target label, $2 = payload, $3 = "expect-refuse" (optional), $EXPECT_APP set
  # Focus safety: never insert unless the expected app is actually frontmost (the user may
  # have taken the keyboard back mid-run).
  if [ -n "${EXPECT_APP:-}" ]; then
    local front=$($CTL frontmost)
    if [ "$front" != "$EXPECT_APP" ]; then
      echo "{\"target\": \"$1\", \"pass\": false, \"skipped\": \"focus lost — frontmost is $front, expected $EXPECT_APP\"}" >> $R
      tail -1 $R
      return 1
    fi
  fi
  printf '%s' "sentinel-clip" | pbcopy
  local out readback clip
  out=$($CTL insert "$2" 2>/dev/null)
  readback=$($CTL read 2>/dev/null)
  clip=$(pbpaste)
  OUT="$out" RB="$readback" CLIP="$clip" LABEL="$1" PAYLOAD="$2" EXPECT="${3:-insert}" \
  python3 - <<'PYEOF' >> $R
import json, os
out = json.loads(os.environ["OUT"]); rb = json.loads(os.environ["RB"])
payload = os.environ["PAYLOAD"]
landed = payload in (rb.get("value") or "") or payload in (rb.get("selectedText") or "")
expect_refuse = os.environ["EXPECT"] == "expect-refuse"
ok = (out["refusedSecureField"] and not out["inserted"]) if expect_refuse \
     else (out["inserted"] and os.environ["CLIP"] == "sentinel-clip")
print(json.dumps({"target": os.environ["LABEL"], "strategy": out["strategy"],
  "inserted": out["inserted"], "clipboard_restored": os.environ["CLIP"] == "sentinel-clip",
  "verified_in_field": landed, "engine_ms": out["elapsedMs"],
  "refused": out["refusedSecureField"], "expected": os.environ["EXPECT"], "pass": ok,
  "detail": out["detail"], "focused_role": rb.get("role"), "app": rb.get("app")}))
PYEOF
  tail -1 $R
}
