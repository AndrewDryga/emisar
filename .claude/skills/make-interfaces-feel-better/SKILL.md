---
name: make-interfaces-feel-better
description: Micro-detail polish for emisar's rendered UI — the small craft that makes an interface feel finished: concentric border radius, optical alignment, shadows vs borders, interruptible/staggered motion, tabular numbers, text-wrap, image outlines, scale-on-press, hit areas, transition specificity. Use when building or reviewing a HEEx/Tailwind component or marketing page, polishing details, or when something "feels off", "feels generic", or you're asked to "make it feel better". The macro art-direction layer is `creative-director`/`design-review`; this is the detail layer under both.
---

# Make interfaces feel better

Great interfaces are rarely one big thing — they're a pile of small details that
compound. This is the **micro-craft** layer that sits under the macro art direction
(`creative-director`, `design-review`) and the screen-level UX (`ux-designer`):
apply it when building or reviewing any rendered HEEx/Tailwind surface.

> Adapted from Jakub Krehel's `make-interfaces-feel-better` skill
> (github.com/jakubkrehel/make-interfaces-feel-better) for emisar's stack:
> **server-rendered HEEx + Tailwind v3.4, no React / framer-motion.** Every
> framer-motion instruction below is translated to Tailwind utilities, CSS, or
> `Phoenix.LiveView.JS`.

## Two house constraints come first

These already hold globally — defer to them, don't re-implement them:

- **Reduced motion is handled in `app.css`** — a `@media (prefers-reduced-motion:
  reduce)` block already neutralizes transitions/animations/pings site-wide. So
  authored motion is safe by construction; you do **not** add a per-element
  reduced-motion guard. Just don't make motion load-bearing for meaning.
- **The focus ring is global** — `:focus-visible` paints one indigo ring on every
  interactive element. Never strip it; never add a bespoke per-component focus style.

## Console vs marketing — where motion is allowed

The polish details split by surface. Get this right or you'll fight `ux-designer`:

- **Operator console (LiveView):** *calm*. Decoration must mean something
  (`ux-designer`). Animate **only** to show a real state change (queued→running, a
  row landing in audit) — never on hover/press for flourish. The detail principles
  that always apply here are the **static** ones: concentric radius, optical
  alignment, shadows-vs-borders, tabular numbers, text-wrap, image outlines, hit
  areas, transition specificity. The motion principles (stagger, press-scale, icon
  cross-fade) are used **sparingly and only when they encode a real change.**
- **Marketing pages (`controllers/marketing_html/**`):** *distinctive*. Authored
  enter/exit motion, press feedback, and staggered reveals are welcome here when the
  creative direction calls for them — they must still have static meaning and survive
  reduced motion (which the global block guarantees).

## Core principles

### 1. Concentric border radius
Outer radius = inner radius + padding. Mismatched radii on nested elements is the
single most common thing that makes a card "feel off". Tailwind: a `rounded-2xl`
(16px) card with `p-2` (8px) wants a `rounded-lg` (8px) inner element — `16 = 8 + 8`.

### 2. Optical over geometric alignment
When geometric centering looks off, align optically. A play `▸`, a chevron, any
asymmetric icon, and icon-plus-label buttons all usually need a manual nudge
(`pl-px`, an asymmetric `px`) — trust the eye, not `items-center` alone.

### 3. Shadows (and rings) over hard borders
Depth wants soft edges, not 1px lines. On marketing, layer two or three transparent
`box-shadow`s for natural depth (shadows adapt to any background; solid borders
don't). On the **dark console** (`bg-zinc-950`), a drop shadow barely reads — get
elevation from a subtle background step plus a low-opacity ring (`ring-1
ring-white/10`) instead of a hard `border-zinc-700`.

### 4. Interruptible animations
Use CSS **transitions** for interactive state changes — they can be interrupted
mid-flight when the state flips back. Reserve `@keyframes` for staged sequences that
run once. For LiveView show/hide, use `Phoenix.LiveView.JS.transition/show/hide`
(CoreComponents already do) rather than hand-rolled toggles.

### 5. Split and stagger enter animations (marketing)
Don't animate one big container. Break the hero into semantic chunks (eyebrow,
headline, sub, CTA) and stagger each by ~100ms with `animation-delay`. A single
`@keyframes rise { from { opacity:0; transform: translateY(8px) } to { opacity:1;
transform:none } }` plus increasing delays reads far better than one block fading in.

### 6. Subtle exit animations (marketing)
Exits should be softer than enters: a small fixed `translateY` (~6–8px) and a fade,
never collapsing full height. A loud exit feels broken.

### 7. Contextual icon swaps — cross-fade, don't toggle
When an icon changes (copy→check, menu→close, sun→moon), never flip `hidden`. We have
**no motion library**, so use the dependency-free path: keep **both** icons in the
DOM, one `absolute`-positioned over the other, and cross-fade with CSS transitions on
`opacity`, `scale`, and `blur` — scale `0.25`→`1`, opacity `0`→`1`, blur `4px`→`0`,
easing `cubic-bezier(0.2, 0, 0, 1)`. This gives both an enter and an exit for free.

### 8. Font smoothing — already done
`-webkit-font-smoothing: antialiased` is already on `<body>` (via the `antialiased`
class in `root.html.heex`). Only re-check it if you introduce a *new* top-level layout.

### 9. Tabular numbers
Any number that updates in place — run/runner counts, timers, durations, a live audit
tally, a marketing stat that ticks — gets `tabular-nums` (Tailwind utility) so digits
don't reflow and shift layout. Partially applied today; extend it to every live count.

### 10. Text wrapping
`text-balance` on headings (evens out ragged multi-line titles); `text-pretty` on body
copy (kills orphans). Both are real Tailwind 3.4 utilities — use the class, not raw CSS.

### 11. Image outlines
Give images and screenshots a 1px low-opacity outline so they don't bleed into the
surface. On our dark UI that's `ring-1 ring-white/10` — pure white at 10%, **never** a
tinted neutral (zinc/slate). A tinted ring picks up the surface under it and reads as
dirt on the image edge.

### 12. Scale on press
A subtle `active:scale-[0.96] transition-transform` gives a button tactile feedback.
Always `0.96` — never below `0.95` (it looks exaggerated). Welcome on marketing CTAs;
on the console reserve it for primary actions and skip it on destructive confirms,
where calm and deliberation beat bounce. (Reduced motion neutralizes it globally.)

### 13. Don't animate default-state elements
Enter animations belong on genuine entrances, not on things already on screen. In
LiveView remember `mount` runs twice and re-renders re-trigger CSS animations — so
keep enter-motion off persistent elements and put it only where a row truly *arrives*
(a `stream` insert). On static marketing pages, on-load enters are intended; elsewhere
they read as jank.

### 14. Never `transition: all`
Always name the properties: `transition-transform`, `transition-colors`,
`transition-opacity` — not `transition-all`. `transition: all` animates properties you
never meant to (and is a perf trap). Tailwind's `transition-transform` already covers
`transform, translate, scale, rotate`.

### 15. `will-change` sparingly
Only on `transform`, `opacity`, `filter` — the properties the GPU composites — and
only when you actually see first-frame stutter. Never `will-change: all`; a permanent
`will-change` wastes memory.

### 16. Minimum hit area
Interactive elements need at least a 40×40px hit area even when the glyph is smaller
(icon buttons, close `×`, table-row actions). Extend the target with padding or a
pseudo-element rather than enlarging the visible icon. Never let two hit areas overlap.

## Common mistakes

| Mistake | Fix |
| --- | --- |
| Same radius on card and inner control | `outer = inner + padding` (§1) |
| Icon/label looks off-center | Nudge optically; don't trust `items-center` alone (§2) |
| Hard `border-zinc-700` for elevation on dark | Background step + `ring-1 ring-white/10` (§3) |
| `hidden`-toggling a changing icon | Cross-fade two stacked icons (§7) |
| Live counts/timers jitter the layout | `tabular-nums` (§9) |
| Ragged headline / body orphans | `text-balance` / `text-pretty` (§10) |
| Tinted ring on an image | `ring-white/10`, pure white (§11) |
| `transition-all` on an element | Name the exact properties (§14) |
| Tiny icon-button tap target | Extend to 40×40px with padding/pseudo (§16) |
| Decorative motion on the console | Remove it — animate only real state change |

## Review output format

When reviewing, present changes as **Before / After** tables grouped by principle —
include every change, not a subset, one diff per row so it scans. Cite the
`file:line` and the exact property when it isn't obvious from the snippet. Omit a
principle's table entirely if nothing needed to change (no empty tables).

#### Concentric border radius
| Before | After |
| --- | --- |
| `rounded-2xl` card (`p-2`) + `rounded-2xl` inner button | inner → `rounded-lg` (`16 = 8 + 8`) |

#### Tabular numbers
| Before | After |
| --- | --- |
| `{@run_count}` in the dashboard tile | wrap in `class="tabular-nums"` |

## Checklist

- [ ] Nested rounded elements use concentric radius
- [ ] Icons optically centered, not just geometrically
- [ ] Elevation from background + ring on dark, not hard borders
- [ ] Changing icons cross-fade (both in DOM), never `hidden`-toggle
- [ ] Live/updating numbers use `tabular-nums`
- [ ] Headings `text-balance`, body `text-pretty`
- [ ] Images carry a pure-white `ring-white/10` outline
- [ ] Press-scale `0.96` where tactile feedback fits the surface
- [ ] No `transition-all` — exact properties only
- [ ] `will-change` only on transform/opacity/filter, and only if stutter is real
- [ ] Interactive elements have ≥40×40px hit area, non-overlapping
- [ ] Console motion encodes a real state change; marketing motion has static meaning
