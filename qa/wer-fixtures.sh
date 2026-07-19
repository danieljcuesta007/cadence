#!/bin/zsh
# §30 eval corpus: TTS utterances with known references, 16 kHz mono WAV (the pipeline's
# native format). Diverse voices/accents/rates and content classes (prose, numbers,
# addresses, technical, commands). TTS is clean audio, so absolute WER here is optimistic
# vs a real mic — the harness's job is RELATIVE model ranking + regression baselining.
# Deterministic: same say(1) voices → same audio → comparable across runs.
set -euo pipefail
cd "$(dirname "$0")/fixtures/wer"

# voice | rate | id | reference text
gen() {
    local voice="$1" rate="$2" id="$3" text="$4"
    say -v "$voice" -r "$rate" -o "$id.wav" --file-format=WAVE --data-format=LEI16@16000 "$text"
    printf '%s\t%s\n' "$id.wav" "$text" >> manifest.tsv
}

setopt null_glob
rm -f manifest.tsv *.wav

gen Samantha 180 s01 "Hey, just checking in about tomorrow's meeting. Can we push it to three thirty instead?"
gen Samantha 220 s02 "The quarterly numbers look strong, revenue grew twelve percent and churn dropped below two percent."
gen Daniel   180 d01 "Please send the invoice to accounts payable by Friday the twenty first."
gen Daniel   210 d02 "I think the root cause is a race condition between the audio callback and the ring buffer clear."
gen Karen    190 k01 "Add milk, eggs, sourdough bread, and two avocados to the shopping list."
gen Karen    230 k02 "The flight departs Sydney at six forty five in the morning and lands in Auckland around noon."
gen Moira    180 m01 "Let's schedule the design review for Wednesday afternoon in the large conference room."
gen Tessa    190 t01 "The new model reduces latency by roughly forty percent while keeping accuracy unchanged."
gen Samantha 170 s03 "Dear team, thank you all for the incredible effort on the launch. Take Friday off, you earned it."
gen Daniel   190 d03 "Navigate to settings, then privacy and security, then microphone, and enable access for Cadence."
gen Karen    200 k03 "My address is forty two Wallaby Way, apartment seven, and the postcode is two thousand."
gen Moira    200 m02 "The recipe needs two cups of flour, a teaspoon of baking soda, and a pinch of salt."
gen Samantha 240 s04 "Honestly the fastest fix is to revert the merge, cut a patch release, and investigate on Monday."
gen Tessa    180 t02 "Encryption keys live in the keychain and the database is never written in plain text."
gen Fred     180 f01 "The train to Boston leaves from platform nine at half past four."

echo "fixtures: $(ls *.wav | wc -l | tr -d ' ') wavs, manifest.tsv written"
