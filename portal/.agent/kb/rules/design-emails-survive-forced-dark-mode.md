# Rule: an email is designed twice, because Gmail redesigns it for us

**Rule.** A color that reaches a mail body clears 4.5:1 **in both directions**:

1. as authored, against its authored ground, and
2. **mirrored** — hue and saturation kept, HSL lightness flipped (`L → 1 − L`) —
   against its mirrored ground.

Every token in `Emisar.Mailers.Style` obeys it and
`Emisar.Mailers.StyleTest` proves it by reflection, so a new one is covered the
moment it is added.

Three consequences, all of them the rule rather than a style choice:

- **Each accent is a step up its own scale, not off it.** An accent survives the
  mirror when it is light and not too saturated. `brand/0` is brand-200 because
  brand-400, the logo emerald, mirrors to 1.8:1 — unreadable rather than dim, and
  short of even the 3:1 large-text bar. `amber/0` is amber-200 for the same
  reason. `rose/0` is rose-300 unchanged, already light and desaturated enough to
  read 10:1 and 12:1.
- **The button is a deep fill under light ink.** The console's bright fill under a
  near-black label reads 9.8:1 as sent and 1.4:1 mirrored; authored the other way
  round it reads the reverse. brand-800 under `ink/0` reads 6.6:1 and 15.9:1.
- **A masthead carries its own ground.** Images are never rewritten, so a
  transparent white-ink logo lands as white ink on a white ground.
  `emisar-email-logo.png` bakes `#09090b` into the lockup with rounded transparent
  corners: invisible on our dark ground, a brand tile on a rewritten one.

**Why.** The Gmail apps ignore `color-scheme`, ignore `prefers-color-scheme`, and
offer no opt-out — Litmus files them under *full color inversion*, the behavior
that turns a dark-designed email light. So the rewritten rendering is going to
exist whether or not anyone designed it, and the founder reported exactly what an
undesigned one looks like: an invisible masthead and washed-out counts.

## What was measured, so nobody re-derives it

| | behavior |
|---|---|
| Gmail web, dark theme | does not rewrite the body at all |
| Gmail app, dark theme | rewrites every authored color by flipping HSL lightness |
| `background-color` | rewritten |
| `background-image` (url or `linear-gradient`) | **exempt** |
| `background` attribute (image) | **exempt** |
| any text color | **rewritten, wherever it sits** |
| `<img>` content | never touched |

Beyond the flip, the app also **dims saturated colors** in dark mode: the same
authored amber renders bright in light mode and dark olive in dark. Treat the
mirror as the floor, not the exact result.

Four ways of avoiding the rewrite were tried and none works: dropping the
`color-scheme` meta, using pure black as the ground, painting every ground with a
gradient, and authoring the `background-color` light so the rewrite would land it
dark and Gmail would infer a dark page. The flip is blind.

## Why the email is not frozen dark

A gradient ground is exempt, so an email *can* be pinned dark in every client.
That was built, shipped to a real inbox, and rejected. Text can never be frozen,
so every tone has to sit at 50% lightness — the one value a flip cannot move —
and there a neutral tops out at `#808080`, 5.0:1. In practice it lands lower,
because the dimming above applies on top. One flat grey for headings, counts,
body and captions, in **every** client including the ones that render the email
correctly today. It made four clients worse to fix one.

Letting the ground flip with the text is what keeps the type crisp: `ink/0` is
near-white on our dark ground and near-black on the mirrored one, 17:1 either way.

## ✅ Good

```elixir
# A step up the scale, so the mirror is a deep green rather than a mid one.
def brand, do: "#95f3cd"
# A deep fill carries light ink in both directions.
def button_fill, do: "#0a6749"
```

```html
<img src="…/emisar-email-logo.png" width="166" height="50" alt="emisar" />
```

## ❌ Bad

```elixir
# Console tokens, dropped into a mail body untested against the mirror.
@brand "#36e6a5"       # mirrors to #19c988 on near-white: 1.8:1
@amber "#fcd34d"       # mirrors to #b28903 on near-white: 2.7:1
@button_fill "#14cf8d" # its near-black label mirrors to white on mint: 1.4:1
```

```html
<!-- Images are never rewritten, so this is white ink on a white ground. -->
<img src="…/emisar-status-logo-dark.png" />
```

## How it's enforced

`Emisar.Mailers.StyleTest` reads `Style`'s exported color functions, treats
`ground`/`surface` as grounds and `hairline`/`button_fill` as chrome, and asserts
every remaining token clears 4.5:1 on both grounds in both directions — plus the
button's label on its fill. Adding a token to `Style` puts it under the bar
automatically.

## Verifying a change by eye

Render the bodies, mirror them, and look at both. The mirror is a five-line
transform over the rendered HTML — flip the HSL lightness of every `#rrggbb`,
leave images alone — which reproduced the founder's Gmail capture exactly,
including the invisible masthead. Shoot the pair side by side and read them
(`.agent/kb/rules/design-ui-fix-screenshot-proof.md`).

A probe email must report its own state inside the body; the Gmail chrome around
a message does not reliably say which rendering you are looking at, and three
probe rounds were misread that way. The pair that works: a masthead image whose
own ground matches the page, so a black rectangle means the page went light, and
a sentence written in the page's own color, invisible until something rewrites it.
