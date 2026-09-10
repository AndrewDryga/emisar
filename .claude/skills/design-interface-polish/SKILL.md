---
name: design-interface-polish
description: "Micro-detail polish for emisar's rendered UI — the small craft that makes an interface feel finished: optical alignment, interruptible motion, icon cross-fades, image outlines, transition specificity, and the LiveView-specific traps around enter animations. Use when building or reviewing a HEEx/Tailwind component or marketing page, polishing details, or when something \"feels off\", \"feels generic\", or you're asked to \"make it feel better\". The macro art-direction layer is `design-creative-director`/`design-review`; this is the detail layer under both."
effort: medium
argument-hint: "[component or page]"
allowed-tools: Read, Grep, Glob, Bash, Write, Edit
---

# Make interfaces feel better

Great interfaces are rarely one big thing — they're a pile of small details that
compound. This is the **micro-craft** layer that sits under the macro art direction
(`design-creative-director`, `design-review`) and the screen-level UX (`design-ux`):
apply it when building or reviewing any rendered HEEx/Tailwind surface.

> Adapted from Jakub Krehel's `make-interfaces-feel-better` skill
> (github.com/jakubkrehel/make-interfaces-feel-better) for emisar's stack:
> **server-rendered HEEx + Tailwind v3.4, no React / framer-motion.** Every
> framer-motion instruction below is translated to Tailwind utilities, CSS, or
> `Phoenix.LiveView.JS`.

## What the design system already fixes — apply, don't restate

[design-system.md](../../../portal/.agent/kb/rules/design-system.md) §3 is the one
home for the values; a polish pass checks the surface against it and cites the
section, never a number from memory:

- concentric radius, elevation on dark (surface step + `ring-white/10`, no hard
  borders), and the minimum hit area — §3.3
- tabular numerals on anything that updates in place, `text-balance` /
  `text-pretty` — §3.2
- the one easing, the shipped `.rise-1…5` stagger, named transition properties
  (never `transition-all`), and the global reduced-motion block — §3.5
- the global focus ring and selection — §3.6
- press feedback (`active:scale-[0.96]`) — the button primitives in §4

## Console vs marketing — where motion is allowed

The polish details split by surface. Get this right or you'll fight `design-ux`:

- **Operator console (LiveView):** *calm*. Decoration must mean something
  (`design-ux`). Animate **only** to show a real state change (queued→running, a
  row landing in audit) — never on hover/press for flourish. The static principles
  always apply here; the motion principles (exits, icon cross-fade) are used
  **sparingly and only when they encode a real change.**
- **Marketing pages (`controllers/marketing_html/**`):** *distinctive*. Authored
  enter/exit motion, press feedback, and staggered reveals are welcome here when the
  creative direction calls for them — they must still have static meaning and survive
  reduced motion (which the global block guarantees).

## Principles the rule leaves to craft

### 1. Optical over geometric alignment
When geometric centering looks off, align optically. A play `▸`, a chevron, any
asymmetric icon, and icon-plus-label buttons all usually need a manual nudge
(`pl-px`, an asymmetric `px`) — trust the eye, not `items-center` alone.

### 2. Interruptible animations
Use CSS **transitions** for interactive state changes — they can be interrupted
mid-flight when the state flips back. Reserve `@keyframes` for staged sequences that
run once. For LiveView show/hide, use `Phoenix.LiveView.JS.transition/show/hide`
(CoreComponents already do) rather than hand-rolled toggles.

### 3. Subtle exit animations (marketing)
Exits should be softer than enters: a small fixed `translateY` (~6–8px) and a fade,
never collapsing full height. A loud exit feels broken.

### 4. Contextual icon swaps — cross-fade, don't toggle
When an icon changes (copy→check, menu→close, sun→moon), never flip `hidden`. We have
**no motion library**, so use the dependency-free path: keep **both** icons in the
DOM, one `absolute`-positioned over the other, and cross-fade with CSS transitions on
`opacity`, `scale`, and `blur` — scale `0.25`→`1`, opacity `0`→`1`, blur `4px`→`0`,
the house easing. This gives both an enter and an exit for free.

### 5. Font smoothing — already done
`-webkit-font-smoothing: antialiased` is already on `<body>` (via the `antialiased`
class in `root.html.heex`). Only re-check it if you introduce a *new* top-level layout.

### 6. Image outlines
Give images and screenshots a 1px low-opacity outline so they don't bleed into the
surface. On our dark UI that's `ring-1 ring-white/10` — pure white at 10%, **never** a
tinted neutral (zinc/slate). A tinted ring picks up the surface under it and reads as
dirt on the image edge.

### 7. Don't animate default-state elements
Enter animations belong on genuine entrances, not on things already on screen. In
LiveView remember `mount` runs twice and re-renders re-trigger CSS animations — so
keep enter-motion off persistent elements and put it only where a row truly *arrives*
(a `stream` insert). On static marketing pages, on-load enters are intended; elsewhere
they read as jank.

### 8. `will-change` sparingly
Only on `transform`, `opacity`, `filter` — the properties the GPU composites — and
only when you actually see first-frame stutter. Never `will-change: all`; a permanent
`will-change` wastes memory.

## Common mistakes

| Mistake | Fix |
| --- | --- |
| Icon/label looks off-center | Nudge optically; don't trust `items-center` alone (§1) |
| `hidden`-toggling a changing icon | Cross-fade two stacked icons (§4) |
| Tinted ring on an image | `ring-white/10`, pure white (§6) |
| Enter animation on a persistent LiveView element | Motion only where a row arrives (§7) |
| A radius, shadow, numeral, easing, or hit-area value from memory | Cite design-system §3 |
| Decorative motion on the console | Remove it — animate only real state change |

## Review output format

When reviewing, present changes as **Before / After** tables grouped by principle —
include every change, not a subset, one diff per row so it scans. Cite the
`file:line` and the exact property when it isn't obvious from the snippet. Omit a
principle's table entirely if nothing needed to change (no empty tables).

#### Concentric border radius (design-system §3.3)
| Before | After |
| --- | --- |
| `rounded-2xl` card (`p-2`) + `rounded-2xl` inner button | inner → `rounded-lg` (`16 = 8 + 8`) |

#### Icon swaps
| Before | After |
| --- | --- |
| copy icon `hidden`-toggled to a check | both icons stacked, cross-faded |

## Checklist

- [ ] Every token-level value checked against design-system §3, not memory
- [ ] Icons optically centered, not just geometrically
- [ ] Interactive state uses transitions; `@keyframes` only for one-shot sequences
- [ ] Changing icons cross-fade (both in DOM), never `hidden`-toggle
- [ ] Images carry a pure-white `ring-white/10` outline
- [ ] Enter motion only where an element truly arrives; none on persistent elements
- [ ] `will-change` only on transform/opacity/filter, and only if stutter is real
- [ ] Console motion encodes a real state change; marketing motion has static meaning
