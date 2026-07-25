#!/bin/zsh
# §30 eval corpus, Spanish. Cadence ships bilingual auto-detect (multilingual small), so the
# Spanish half of that claim needs its own held-out set — until 2026-07-25 it had none.
#
# Separate directory from the English fixtures on purpose: the English generator wipes its own
# `*.wav`, and one mixed manifest would score English-only models (base.en, small.en) against
# Spanish audio, which measures nothing.
#
# Run with the default language setting (auto), NOT `CADENCE_LANG=es` — the thing under test is
# whether auto-detect picks Spanish on its own, which is what a bilingual user actually gets.
#
# References avoid digits: the scorer expands digit tokens to ENGLISH number words, so "42" vs
# "cuarenta y dos" would score as a normalization artifact rather than a recognition error.
# Accents are folded on both sides by wer.py, so writing them correctly here is free.
set -euo pipefail
cd "$(dirname "$0")/fixtures/wer-es"

# voice | rate | id | reference text
gen() {
    local voice="$1" rate="$2" id="$3" text="$4"
    say -v "$voice" -r "$rate" -o "$id.wav" --file-format=WAVE --data-format=LEI16@16000 "$text"
    printf '%s\t%s\n' "$id.wav" "$text" >> manifest.tsv
}

setopt null_glob
rm -f manifest.tsv *.wav

# Voices span Spain and Mexico so the set is not tuned to one accent.
gen "Mónica" 180 e01 "Hola, quería confirmar la reunión de mañana por la tarde en la oficina."
gen "Mónica" 210 e02 "Los resultados del trimestre son buenos, los ingresos subieron y la cancelación bajó."
gen "Paulina" 180 e03 "Por favor envía la factura al departamento de contabilidad antes del viernes."
gen "Paulina" 210 e04 "Creo que el problema está entre la captura de audio y el búfer circular."
gen "Jorge" 190 e05 "Añade leche, huevos, pan de masa madre y dos aguacates a la lista de compras."
gen "Juan" 190 e06 "El vuelo sale de Madrid por la mañana y llega a Buenos Aires por la noche."
gen "Mónica" 200 e07 "Vamos a programar la revisión de diseño para el miércoles en la sala grande."
gen "Diego" 190 e08 "El modelo nuevo reduce la latencia y mantiene la precisión sin cambios."
gen "Paulina" 170 e09 "Estimado equipo, gracias por el esfuerzo increíble en el lanzamiento de esta semana."
gen "Jorge" 190 e10 "Abre configuración, luego privacidad y seguridad, después micrófono, y activa el acceso."
gen "Mónica" 200 e11 "La receta necesita dos tazas de harina, una cucharadita de bicarbonato y una pizca de sal."
gen "Diego" 220 e12 "Honestamente, lo más rápido es revertir el cambio y revisarlo el lunes con calma."
gen "Juan" 180 e13 "Las claves de cifrado viven en el llavero y la base de datos nunca se guarda en texto plano."
gen "Paulina" 190 e14 "El tren a Barcelona sale del andén nueve y tarda unas tres horas en llegar."
gen "Mónica" 190 e15 "Necesito reservar una mesa para cuatro personas el sábado por la noche cerca de la playa."

echo "spanish fixtures: $(ls *.wav | wc -l | tr -d ' ') wavs, manifest.tsv written"
