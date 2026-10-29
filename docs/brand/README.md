# Cadence brand, v1 (riso)

Cadence looks like a risograph print: two inks on cream paper (cobalt and Cadence green), drawn with one confident
line. It's warm, a little handmade and a little off-register. That suits a tool about your
own voice, and it sets Cadence apart from the glossy gradients every other dictation app uses.
Adopted 29 Oct 2026, when Daniel picked the riso direction for Cadence marketing. The fill ink is Cadence green rather than the reference's pink, so the brand keeps the green the app already uses.

The source files live in [`site/art/`](../../site/art/), the one place the site and this
guide both read from. Don't copy them anywhere else.

![Brand guide](cadence-brand-guide.png)

## Paper and inks

One paper and three inks. The art is printed only in the three inks, and the paper is whatever it sits on.

| Colour | Hex | Use |
| --- | --- | --- |
| Paper | `#F3ECDC` | Background, and the card behind every illustration |
| Cobalt | `#2443C4` | Line work, headings, buttons. The main ink |
| Green | `#5CB567` | Fills, and the offset "plate" shadow behind cards and buttons. The app's own green, so the site, the app and the icon share one colour |
| Red | `#EC4A32` | The spot colour: one accent per view (mouth, caret, peak bar) |

Small red **text** (labels, kickers) uses the deeper `#B02D18`, because bright red on cream
is only 3.2:1. The deeper red passes WCAG AA (4.5:1) on every surface.

Night mode keeps the same inks on a deep ink-blue sheet (`#141A3D`). Cobalt and red *text* lift to
`#8FA2FF` and `#FF7A63` so they stay readable (site tokens only, never inside the art), and the illustrations stay on cream cards, like prints
pinned to a dark wall.

## Rules for the art

- **Two plates.** The green plate prints first and sits slightly off register (about 5px
  down-right). Cobalt line work prints over it, and red is used sparingly.
- **Line.** One weight per drawing (6–7 at the drawing's scale), with round caps and joins.
  There are no gradients and no outlines on the green.
- **Grain.** Every ink carries the same speckle filter (`#grain`, fractal noise, seed 7),
  so the colour looks pressed into the paper rather than flat. Apply it once, on one group
  that wraps the whole drawing.
- **Only the three inks.** No paper fill inside the art. The site tests reject any other colour in `site/art/`.
- **Self-contained.** No scripts, no inline CSS, no remote fonts or images. The site's
  strict Content-Security-Policy covers the SVGs too.
- **Original.** Draw the art fresh. Riso is the technique, not a borrowed character.

## The set

| File | What it shows | Where |
| --- | --- | --- |
| `announcer.svg` | A radio announcer at a vintage mic; the words leave as a ribbon of type | Hero |
| `hold.svg` | A finger pressing the Option key | Step 1 |
| `speak.svg` | A microphone with sound coming in from both sides | Step 2 |
| `release.svg` | A page of fresh type with a red caret | Step 3 |
| `jar.svg` | A laptop under a bell jar: nothing leaves your Mac | Privacy feature |
| `bubbles.svg` | "hi" and "hola" | Two-languages feature |
| `mark.svg` | Five voice-level bars, with the tallest in red | Header, footer |

## Type

- **Display:** Iowan Old Style, then New York, then Georgia, in bold. Italic is for the red
  second line of a headline.
- **Labels:** the system sans in small capitals with wide tracking (0.24em), in red.
- **Body:** the system sans.

All three are system fonts, so nothing is downloaded.

## Voice

Plain and confident. Say what it does: "Speak. It types." Don't use emojis, and don't
use exclamation marks.

## Not changed by v1

The app icon (`platform-macos/.../AppIcon`) and the in-app green (`BrandColor.swift`) stay as
they are. v1 covers marketing: the site, social images and release art. Bringing the app
itself into the riso system is a separate decision.
