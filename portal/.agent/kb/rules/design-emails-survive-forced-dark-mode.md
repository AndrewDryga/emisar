# Rule: an email is designed twice, because Gmail redesigns it for us

**Rule.** An HTML email body is rendered by clients we do not control, and the
Gmail mobile apps rewrite every color we author. So a color that reaches a mail
body clears its contrast bar **in both directions**:

1. as authored, against its authored ground, and
2. **mirrored** — hue and saturation kept, HSL lightness flipped (`L → 1 − L`) —
   against its mirrored ground.

Every color in `Emisar.Mailers.Style` obeys this, and `Emisar.Mailers.StyleTest`
proves it by reflection, so a new token is covered the moment it is added.

Two structural consequences follow, and both are the rule, not a style choice:

- **An accent sits lighter than its console counterpart.** A mid-lightness
  saturated accent mirrors into another mid-lightness saturated color, so a
  filled button keeps its fill's brightness while its label flips across —
  console-weight `#14cf8d` with a near-black label mirrors to a pale mint with a
  white one, at 1.4:1. Pushing the accent up (`#8df0ca`) mirrors it down to a
  deep green a white label sits on, at 5.4:1.
- **A masthead carries its own ground.** An inverting client rewrites CSS colors
  and leaves images alone, so a transparent white-ink logo lands as white ink on
  a white ground. `emisar-email-logo.png` bakes the `#09090b` ground into the
  lockup with rounded transparent corners: invisible on our dark ground,
  a brand tile on an inverted one.

**Why.** Gmail's mobile apps ignore `<meta name="color-scheme">`, ignore
`prefers-color-scheme`, and offer no opt-out. A dark-designed email is delivered
to a Gmail dark-mode reader as a *light* one, and if we have not designed that
light rendering, nobody has. The founder reported the monthly report arriving
with an invisible masthead and washed-out counts; the failing colors were exactly
the accents and the filled CTA.

`prefers-color-scheme` still matters for Apple Mail and Outlook.com and the
`color-scheme` meta still tells them the body is handled — this rule is about the
client that does not ask.

## ✅ Good

```elixir
# One emerald covers link, eyebrow, bullet, count, and button fill. Its mirror is
# a deep green, so the button's ground-colored label mirrors to white on it.
def brand, do: "#8df0ca"
```

```html
<img src="…/emisar-email-logo.png" width="166" height="50" alt="emisar" />
```

## ❌ Bad

```elixir
# Console tokens, dropped into a mail body untested against the mirror.
@brand_fill "#14cf8d"   # mirrors to #30eba9; the white label reads at 1.4:1
@amber "#fcd34d"        # mirrors to #b28903 on near-white: 2.7:1
@ink_zero "#71717a"     # mirrors to #85858e on near-white: 3.1:1
```

```html
<!-- Images are never inverted, so this is white ink on a white ground. -->
<img src="…/emisar-status-logo-dark.png" />
```

## How it's enforced

`Emisar.Mailers.StyleTest` reads `Style`'s exported color functions, treats
`ground`/`surface` as grounds and `hairline` as a separator, and asserts every
remaining token clears 4.5:1 on both grounds in both directions — plus the
button's ground-colored label on the brand fill. Adding a token to `Style` puts
it under the bar automatically.

## Verifying a change by eye

Render the bodies, mirror them, and look at both. The mirror is a five-line
transform over the rendered HTML — flip the HSL lightness of every `#rrggbb`,
leave images alone — which reproduced the founder's Gmail capture exactly,
including the invisible masthead. Shoot the pair side by side and read them
(`.agent/kb/rules/design-ui-fix-screenshot-proof.md`).
