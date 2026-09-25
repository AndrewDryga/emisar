# Rule: an email stays dark in the Gmail apps, because Gmail rewrites what it can reach

**Founder requirement, not polish.** The emails are designed dark and must stay
dark in both Gmail themes (asked 2026-09-02, confirmed on the founder's phone).
A simplification pass ranked these devices as disproportionate and deleted them
on 2026-09-03; Gmail on iOS then turned every email light (near-white ground,
grey text, the logo tile a black chip) until they were restored on 2026-09-25.
Do not remove or "simplify" them without the founder's decision.

**Rule.** A mail body keeps its design in the Gmail apps through four devices,
and `Emisar.Mailers.Style` owns all of them:

- **`fill/1` + its `gm-` class** paints every surface. `gmail_css/0` repaints the
  class with a gradient, which Gmail never rewrites, so grounds, card and plate
  interiors, and the button fill hold.
- **`blend/1`** wraps neutral text in nested `screen` and `difference` layers.
  The math is a no-op when nothing was flipped and undoes the flip when it was.
  `blend/2` does it only when the text's color is a neutral.
- **Accents sit at 50% HSL lightness**, the one value a lightness flip leaves
  alone, because no blend can carry a hue.
- **No borders.** A border is not a background and cannot be painted, so a
  divider is a `rule/1` row and a container's outline is an `edge/0` fill one
  pixel outside the container's own fill (a table wrapping a table, `padding:1px`).

## Why it is built this way

The Gmail apps rewrite every authored color by flipping its HSL lightness,
ignore `color-scheme` and `prefers-color-scheme`, and Litmus files them under
*full color inversion* — the behavior that turns a dark email light. There is no
way to switch it off.

But Gmail can be **targeted**. It replaces the doctype with a `<u></u>` and turns
`<body>` into a div, so `u + .body` matches inside Gmail and nowhere else — the
counterpart of Outlook.com's `[data-ogsc]`. `gmail_css/0` is that block, and
`Style.document/4` puts it in the head and `class="body"` on the body.

The catch, measured on a real device: the block applies in **both** Gmail themes
while the rewrite happens in only one. So no declared color can serve both —
naming a color outright is right in light mode and wrong in dark, and naming its
mirror is exactly the reverse. Only self-correcting devices work, which is why
the four above are what they are.

The gradient lives only in the block, never inline. Where a Gmail app drops
embedded CSS (a non-Google account in the Gmail app), the ground must flip with
the text; an inline gradient would hold the ground dark while the text flips
dark on it. In that fallback the body goes light and the neutrals, which clear
4.5:1 flipped (6.2:1 at worst), stay readable; the 50%-lightness accents do not
(emerald 1.5:1, amber 1.6:1, rose 3.6:1 on the light ground). That is the
accepted cost of brand-hue accents everywhere else; the old pale palette would
instead fail inside Gmail itself once the ground holds (rose 1.4:1).

## What was measured (probe emails read on the founder's phone, 2026-09-02)

| | behavior |
|---|---|
| Gmail web, dark theme | does not rewrite the body |
| Gmail app, dark theme | flips the HSL lightness of every authored color |
| `background-color`, `bgcolor` | rewritten |
| `background-image` (url or `linear-gradient`) | **exempt** |
| any text color | **rewritten, wherever it sits** |
| `background-clip: text` | **stripped** — the gradient-painted-text trick does not survive |
| `<style>`-declared color | rewritten, exactly like an inline one |
| `mix-blend-mode` | **supported** — this is what carries the text |
| `<img>` content | never touched |

Approaches that do not work, each sent and read rather than reasoned about:
dropping the `color-scheme` meta, using pure black as the ground, painting every
ground with a gradient and nothing else, authoring the `background-color` light so
the rewrite would land it dark, pre-flipped colors in the block, and
`background-clip: text`.

## Two things the blend cannot do

**It cannot carry a hue.** Blend modes are per-channel RGB operations and the
rewrite is an HSL flip, so a blended accent comes back as its RGB complement —
emerald returns pink. Accents therefore stay outside `blend/1` and sit at the
fixed point instead. That constrains three colors rather than the palette: the
neutrals keep their full contrast, so `ink/0` is still near-white.

**It needs a dark backdrop.** `screen` is only an identity over a dark surface;
over a bright one it washes a dark label into the fill. That is why
`button_fill/0` is brand-800 with `ink/0` on it rather than the console's
brand-500 with a near-black label.

## ✅ Good

```elixir
def brand, do: "#1ce399"          # brand-400's hue at the fixed point
~s(<td class="gm-surface" style="#{Style.fill(@surface)}border-radius:9px;">#{Style.blend(text)}</td>)
Style.blend(~s(<strong style="color:#{color};">#{status}</strong>), color)
```

## ❌ Bad

```elixir
# A hue off the fixed point moves, and no blend can hold it.
def brand, do: "#8df0ca"
```

```html
<!-- A background with no gm- class is rewritten to its opposite. -->
<td style="background-color:#111114;">
<!-- A border is not a background: this flips to a bright line. -->
<td style="border-top:1px solid #27272a;">
<!-- An accent inside a blend comes back as its complement. -->
<span class="gm-screen"><span class="gm-difference"><a style="color:#1ce399;">…</a></span></span>
```

## How it's enforced

`Emisar.Mailers.StyleTest`: every ink clears 4.5:1 on both grounds; every accent
sits within half a percent of 50% lightness; the neutrals clear 4.5:1 flipped;
the button label clears 4.5:1 on its fill. It renders both mailers and fails on a
missing Gmail block or `body` class, on a `background-color` without the `gm-`
class that repaints its own color, on any `1px` border, and on `bgcolor`.

## Verifying a change by eye

Reproduce Gmail's DOM — a `<u></u>` sibling before the body turned into a div —
then flip the HSL lightness of every `#rrggbb` outside a `linear-gradient()`,
including those in the `<style>` block, and leave images alone. Under this design
the authored and flipped renderings are near-identical, which is the point.
Headless Chrome clamps windows to 500px; render a phone width through a sized
iframe.

A probe email must report its own state inside the body; the Gmail chrome around
a message does not reliably say which rendering you are looking at, and three
probe rounds were misread that way before this was learned.
