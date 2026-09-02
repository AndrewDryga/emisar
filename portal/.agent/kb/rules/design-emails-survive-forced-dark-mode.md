# Rule: an email is frozen, because Gmail rewrites everything it can

**Rule.** A mail body paints every surface with `Emisar.Mailers.Style.fill/1` — a
gradient — and gives every text tone 50% HSL lightness. Nothing else survives a
rewriting client:

- a **gradient or image background is never rewritten**, so a painted ground
  stays dark everywhere;
- **text is always rewritten**, whatever it sits on, and 50% lightness is the one
  value a lightness flip cannot move.

Two things follow, and both are the rule rather than a style choice:

- **There is one neutral.** At 50% lightness a grey tops out at `#808080`, 5.0:1
  on our ground. Headings, counts, body copy and captions all wear `ink/0`;
  hierarchy comes from size and weight. Saturated hues are unharmed at that
  lightness — emerald reads 15:1, amber 12:1 — so the accents carry more weight
  here than they do in the console.
- **There are no borders.** A border is not a background and cannot be frozen, so
  a hairline flips to a bright line across a dark card. Rules are `Style.rule/1`
  rows; a card edge is `fill/1` wrapping `fill/1`, one pixel apart.

Outlook renders no gradient, so the ground reaches it through
`Style.mso_fallback/1` — a conditional comment Gmail never parses. It must not
ride along as a `background-color`, which Gmail reads and rewrites.

**Why.** The founder reported the monthly report arriving unreadable in the Gmail
app's dark theme. Six probe emails and the published research agree: Litmus files
the Gmail app under *full color inversion*, the behavior that turns a dark email
light, and there is no opt-out — no meta, no selector, no hack. `[data-ogsc]` and
`[data-ogsb]` target Outlook.com, not Gmail, and Gmail ignores
`prefers-color-scheme` entirely.

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

Three things were tried and do not work: removing the `color-scheme` meta, using
pure black as the ground, and authoring the `background-color` light so the
rewrite would land it on dark and Gmail would infer a dark page. Text was flipped
in every case, which is what makes it *blind* rather than contrast-aware.

## The alternative, and why it was not taken

Letting the ground flip with the text produces a readable *light* email in the
Gmail app while staying dark everywhere else. It was shipped first and rejected:
making both directions legible forces the accents pale — brand emerald mirrors to
1.8:1 and brand amber to 2.7:1, unreadable rather than merely dim, failing even
the 3:1 large-text bar — and pale accents are off-brand in every client, not just
the one that rewrites. Freezing costs one neutral; the alternative costs the
palette.

## ✅ Good

```elixir
# A painted ground, and tones at the fixed point of a lightness flip.
def fill(color), do: "background-image:linear-gradient(#{color},#{color});"
def ink, do: "#808080"
def brand, do: "#00ffa1"
```

```html
<td style="background-image:linear-gradient(#27272a,#27272a);border-radius:12px;">
  <td style="padding:1px;">
    <table style="background-image:linear-gradient(#111114,#111114);border-radius:11px;">
```

## ❌ Bad

```html
<!-- Rewritten to #f4f4f6, which turns the whole email light. -->
<body style="background-color:#09090b;">

<!-- Not a background, so it cannot be frozen: this flips to a bright line. -->
<td style="border-top:1px solid #27272a;">
```

```elixir
# A solid emerald fill cannot hold a label. Authored dark it reads 9.8:1 and
# flips to 1.4:1; authored light it reads the reverse. The button is tonal:
# a frozen dark fill under a brand-coloured label.
~s(<td bgcolor="#14cf8d"><a style="color:#09090b">)
```

## How it's enforced

`Emisar.Mailers.StyleTest` reads `Style`'s exported color functions, treats
`ground`/`surface` as grounds and `hairline`/`button_fill` as chrome, and asserts
every remaining token clears 4.5:1 on both grounds as authored **and** after a
flip — plus the button label on its fill. It then renders both bodies and fails
on any `background-color` or `1px` border reaching them, and on a missing Outlook
ground. Adding a token to `Style` puts it under the bar automatically.

## Verifying a change by eye

Render the bodies, apply the rewrite, and look at both. The rewrite is a short
transform over the rendered HTML — flip the HSL lightness of every `#rrggbb`,
skipping anything inside a `linear-gradient()`, and leave images alone. Under
this design the two renderings are near-identical, which is the point. Shoot the
pair side by side and read them
(`.agent/kb/rules/design-ui-fix-screenshot-proof.md`).
