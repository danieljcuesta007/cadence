#!/bin/zsh
# §30 model eval: run every fixture through the REAL pipeline (cadence-headless, verbatim
# mode so cleanup doesn't rewrite the hypothesis) for each candidate model; score WER +
# ASR latency; write qa/wer-results.json and print a ranking table.
#
# Usage: qa/wer-harness.sh [model.bin ...]   (default: every ggml-*.bin in models/artifacts)
set -euo pipefail
cd "$(dirname "$0")/.."
source ~/.cargo/env
export CMAKE="${CMAKE:-$PWD/tools/cmake-local/cmake-3.31.7-macos-universal/CMake.app/Contents/bin/cmake}"

BIN=target/release/cadence-headless
cargo build --release -p cadence-headless --features whisper 2>/dev/null | true
[[ -x "$BIN" ]] || { echo "build failed: $BIN missing" >&2; exit 1; }

MODELS=("$@")
if (( ${#MODELS[@]} == 0 )); then
    MODELS=(models/artifacts/ggml-*.bin)
fi

MANIFEST=qa/fixtures/wer/manifest.tsv
[[ -f "$MANIFEST" ]] || { echo "run qa/wer-fixtures.sh first" >&2; exit 1; }

OUT=qa/wer-results.json
python3 - "$BIN" "$MANIFEST" "$OUT" "${MODELS[@]}" <<'EOF'
import json, subprocess, sys, time
sys.path.insert(0, "qa")
from wer import normalize, wer

bin_, manifest, out_path, *models = sys.argv[1:]
fixtures = []
for line in open(manifest):
    wav, ref = line.rstrip("\n").split("\t")
    fixtures.append((wav, ref))

results = {}
for model in models:
    rows, total_err, total_ref, asr_ms = [], 0, 0, []
    for wav, ref in fixtures:
        p = subprocess.run(
            [bin_, "--wav", f"qa/fixtures/wer/{wav}", "--verbatim", "--model", model],
            capture_output=True, text=True, timeout=180)
        if p.returncode != 0:
            rows.append({"wav": wav, "error": p.stderr.strip()[-200:]})
            continue
        rep = json.loads(p.stdout)
        hyp = rep.get("refined_transcript") or ""
        m = wer(normalize(ref), normalize(hyp))
        m.update(wav=wav, hyp=hyp, asr_ms=rep["timings_ms"]["asr"])
        rows.append(m)
        total_err += m["errors"]; total_ref += m["ref_words"]
        asr_ms.append(rep["timings_ms"]["asr"])
    agg = {
        "wer": total_err / max(total_ref, 1),
        "errors": total_err, "ref_words": total_ref,
        "asr_ms_mean": sum(asr_ms) / max(len(asr_ms), 1),
        "asr_ms_max": max(asr_ms) if asr_ms else None,
        "fixtures": rows,
    }
    results[model] = agg
    print(f"{model}: WER {agg['wer']:.3%} ({total_err}/{total_ref}) "
          f"asr {agg['asr_ms_mean']:.0f} ms mean / {agg['asr_ms_max']} ms max")

json.dump({"generated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
           "results": results}, open(out_path, "w"), indent=1)
print(f"wrote {out_path}")
EOF
