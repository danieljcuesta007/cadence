#!/usr/bin/env python3
"""§30 WER scorer: reference vs hypothesis word error rate.

Normalization before alignment (both sides): lowercase; punctuation stripped; number
words are NOT converted (whisper may emit digits for spoken numbers, so digit sequences
are expanded to a canonical spoken form for fairness: "3:30" ≠ "three thirty" would be
two errors of tokenization, not recognition).

Usage: wer.py <reference> <hypothesis>   (prints json {wer, sub, del, ins, ref_words})
   or: wer.py --self-test
"""
import json
import re
import sys
import unicodedata

_SMALL = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
_TENS = "twenty thirty forty fifty sixty seventy eighty ninety".split()


def _num_words(n: int) -> str:
    if n < 20:
        return _SMALL[n]
    if n < 100:
        t, r = divmod(n, 10)
        return _TENS[t - 2] + (" " + _SMALL[r] if r else "")
    if n < 1000:
        h, r = divmod(n, 100)
        return _SMALL[h] + " hundred" + (" " + _num_words(r) if r else "")
    if n < 1_000_000:
        th, r = divmod(n, 1000)
        return _num_words(th) + " thousand" + (" " + _num_words(r) if r else "")
    return str(n)


def _expand_token(tok: str) -> str:
    # "3:30" -> "three thirty"; "21st" -> "twenty first"-ish is too fuzzy: keep ordinal digits
    # as cardinal words (references avoid digit ordinals). "12%" handled by punctuation strip.
    if re.fullmatch(r"\d{1,2}:\d{2}", tok):
        h, m = tok.split(":")
        m_i = int(m)
        m_txt = "o'clock" if m_i == 0 else ("oh " + _num_words(m_i) if m_i < 10 else _num_words(m_i))
        return _num_words(int(h)) + " " + m_txt
    if re.fullmatch(r"\d+", tok):
        return _num_words(int(tok))
    return tok


def _fold_diacritics(text: str) -> str:
    """Strip combining marks: "canción" -> "cancion", "años" -> "anos".

    The token filter below keeps only `[a-z0-9:' ]`, so without this every accented Spanish
    word would be split into fragments ("canción" -> "canci n") and score as two errors of
    encoding rather than recognition. Folding is applied to BOTH sides, so a model that gets
    the accent right and one that drops it are scored identically — the honest comparison for
    a dictation tool whose output is judged on words, not diacritics.
    """
    return "".join(
        c for c in unicodedata.normalize("NFD", text) if unicodedata.category(c) != "Mn"
    )


def normalize(text: str) -> list[str]:
    text = _fold_diacritics(text.lower())
    text = text.replace("'", "'")
    # Symbols whisper writes that the reference speaks: expand before punctuation strip,
    # or the spoken word counts as a phantom deletion.
    text = text.replace("%", " percent ").replace("&", " and ").replace("$", " dollars ")
    # Keep digits and colons through the first pass so times survive to expansion.
    text = re.sub(r"[^a-z0-9:' ]+", " ", text)
    out: list[str] = []
    for tok in text.split():
        tok = tok.strip(":'")
        if not tok:
            continue
        out.extend(_expand_token(tok).replace("'", " ").split())
    return out


def wer(ref: list[str], hyp: list[str]) -> dict:
    # Standard Levenshtein alignment with backtrace counts.
    R, H = len(ref), len(hyp)
    d = [[0] * (H + 1) for _ in range(R + 1)]
    for i in range(R + 1):
        d[i][0] = i
    for j in range(H + 1):
        d[0][j] = j
    for i in range(1, R + 1):
        for j in range(1, H + 1):
            c = 0 if ref[i - 1] == hyp[j - 1] else 1
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + c)
    i, j, sub, dele, ins = R, H, 0, 0, 0
    while i > 0 or j > 0:
        if i > 0 and j > 0 and d[i][j] == d[i - 1][j - 1] + (ref[i - 1] != hyp[j - 1]):
            sub += ref[i - 1] != hyp[j - 1]
            i, j = i - 1, j - 1
        elif i > 0 and d[i][j] == d[i - 1][j] + 1:
            dele += 1
            i -= 1
        else:
            ins += 1
            j -= 1
    errors = sub + dele + ins
    return {
        "wer": errors / max(R, 1),
        "sub": sub,
        "del": dele,
        "ins": ins,
        "ref_words": R,
        "errors": errors,
    }


def self_test() -> None:
    assert normalize("It's 3:30, twelve percent!") == ["it", "s", "three", "thirty", "twelve", "percent"]
    assert normalize("The 42 avocados") == ["the", "forty", "two", "avocados"]
    # Spanish: accents fold instead of shattering the word, and ¿¡ vanish with other punctuation.
    assert normalize("¿Cuándo está la reunión?") == ["cuando", "esta", "la", "reunion"]
    assert normalize("Añadir canción") == ["anadir", "cancion"]
    # Folding is symmetric, so dropping an accent is never scored as an error.
    assert normalize("reunión") == normalize("reunion")
    r = wer(["a", "b", "c"], ["a", "x", "c"])
    assert (r["wer"], r["sub"]) == (1 / 3, 1), r
    r = wer(["a", "b"], ["a", "b"])
    assert r["wer"] == 0.0
    r = wer(["a", "b", "c", "d"], ["b", "c"])
    assert r["errors"] == 2 and r["del"] == 2, r
    print("wer.py self-test OK")


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        self_test()
        sys.exit(0)
    ref, hyp = sys.argv[1], sys.argv[2]
    print(json.dumps(wer(normalize(ref), normalize(hyp))))
