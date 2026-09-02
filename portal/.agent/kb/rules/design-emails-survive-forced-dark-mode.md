# Rule: an email is held in place, because Gmail rewrites what it can reach

**Rule.** A mail body keeps its design in a rewriting client through three
devices, and `Emisar.Mailers.Style` owns all of them:

- **`fill/1` + its `gm-` class** paints every surface. A gradient is never
  rewritten, so grounds, card interiors and the button fill hold.
- **`blend/1`** wraps neutral text in nested `screen` and `difference` layers.
  The math is a no-op when nothing was inverted and undoes the inversion when
  something was.
- **Accents sit at 50% HSL lightness**, the one value a lightness flip leaves
  alone, because no blend can carry a hue.

Borders are gone: a border is not a background and cannot be painted, so a rule
is a `rule/1` row and a card edge is `fill/1` wrapping `fill/1`, a pixel apart.

## Why it is built this way

The Gmail apps rewrite every authored color by flipping its HSL lightness, ignore
`color-scheme` and `prefers-color-scheme`, and Litmus files them under *full
color inversion* — the behavior that turns a dark email light. There is no way to
switch it off.

But Gmail can be **targeted**. It replaces the doctype with a `<u></u>` and strips
`<body>` into a div, so `u + .body` matches inside Gmail and nowhere else — the
counterpart of Outlook.com's `[data-ogsc]`. `gmail_css/0` is that block.

The catch measured on a real device: the block applies in **both** Gmail themes
while the rewrite happens in only one. So no declared color can serve both —
naming a color outright is right in light mode and wrong in dark, and naming its
mirror is exactly the reverse. Both were sent and read. Only self-correcting
devices work, which is why the three above are what they are.

## What was measured

| | behavior |
|---|---|
| Gmail web, dark theme | does not rewrite the body |
| Gmail app, dark theme | flips the HSL lightness of every authored color |
| `background-color` | rewritten |
| `background-image` (url or `linear-gradient`) | **exempt** |
| any text color | **rewritten, wherever it sits** |
| `background-clip: text` | **stripped** — the gradient-painted-text trick does not survive |
| `<style>`-declared color | rewritten, exactly like an inline one |
| `mix-blend-mode` | **supported** — this is what carries the text |
| `<img>` content | never touched |

Approaches that do not work, each sent and read rather than reasoned about:
dropping the `color-scheme` meta, using pure black as the ground, painting every
ground with a gradient and nothing else, authoring the `background-color` light so
the rewrite would land it dark, and `background-clip: text`.

## Two things the blend cannot do

**It cannot carry a hue.** Blend modes are per-channel RGB operations and the
rewrite is an HSL flip, so a blended accent comes back as its RGB complement —
emerald returns pink. Accents therefore stay outside `blend/1` and sit at the
fixed point instead. That constrains three colors rather than the palette, which
is what separates this from flattening the design: the neutrals keep their full
contrast, so `ink/0` is still near-white.

**It needs a dark backdrop.** `screen` is only an identity over a dark surface;
over a bright one it washes a dark label into the fill. That is why
`button_fill/0` is brand-800 with `ink/0` on it rather than the console's
brand-500 with a near-black label.

## ✅ Good

```elixir
def brand, do: "#1ce399"          # brand-400's hue at the fixed point
def fill(color), do: "background-color:#{color};"
def blend(content), do: ~s(<span class="gm-screen"><span class="gm-difference">#{content}</span></span>)
```

```html
<td class="gm-surface" style="background-color:#111114;">
```

## ❌ Bad

```elixir
# A hue off the fixed point moves, and no blend can hold it.
def brand, do: "#36e6a5"

# background-clip is stripped; the text falls back to the flipped inline colour.
"background-image:linear-gradient(#fafafa,#fafafa);background-clip:text;color:transparent;"
```

```html
<!-- A background with no gm- class is rewritten to its opposite. -->
<td style="background-color:#111114;">
<!-- A border is not a background: this flips to a bright line. -->
<td style="border-top:1px solid #27272a;">
```

## How it's enforced

`Emisar.Mailers.StyleTest` reflects over `Style`'s color functions: every tone
clears 4.5:1 on both grounds, and every accent must sit within half a percent of
50% lightness. It then renders both bodies and fails on a background with no
`gm-` class, on any `1px` border, and on a missing Gmail block or `body` class.

## Verifying a change by eye

Reproduce Gmail's DOM — a `<u></u>` sibling before the body as a div — then flip
the HSL lightness of every `#rrggbb` outside a `linear-gradient()`. Under this
design the two renderings are near-identical, which is the point.

A probe email must report its own state inside the body; the Gmail chrome around
a message does not reliably say which rendering you are looking at, and three
probe rounds were misread that way before this was learned.
