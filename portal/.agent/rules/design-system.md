# emisar Design System — "The Gate"

> The single source of truth for the emisar visual language: the taste, tokens,
> brand, components, patterns, and the **plan to bring the operator console into
> line with the redesigned marketing site**. Read this before any visual change
> to `emisar_web` (marketing **or** console). Grounded in
> `assets/tailwind.config.js`, `assets/css/app.css`, and
> `lib/emisar_web/components/core_components.ex` — when those change, change this.

---

## 0. State — where the redesign is (2026-06-22)

- **Marketing site: redesigned + shipped.** The 28 marketing pages
  (`controllers/marketing_html/`) run the "Gate" direction: emerald `brand`
  accent, semantic pass/pending/deny palette, signature type, materiality
  primitives, restrained motion, and the new logo system. See
  `[[marketing-redesign-gate-direction]]` (memory) for the full engagement log.
- **Logo: replaced + rolled out.** New chevron-gate icon + custom wordmark; full
  favicon/app-icon/OG set. Assets in `priv/static/images/brand/` + the favicon
  family at the static root. `<.brand>` and `<.gate_mark>` rebuilt.
- **Operator console: NOT yet aligned.** The console
  (`live/**`, most of `core_components.ex`) still carries **legacy indigo
  accents** and **Tailwind `emerald-*`** for success — two greens that don't
  match the logo, plus a stray accent hue. The global a11y tokens (focus ring +
  selection) were already migrated to `brand`. **Closing this gap is the job
  this doc exists to enable.**

**The goal:** the console should feel like the same product as the marketing
site — same emerald, same type, same semantics, same crafted component detail —
**without** importing marketing's expressive materiality. See §8 (the two
registers) and §9 (the migration plan).

---

## 1. Principles (the taste)

1. **The Gate is the metaphor.** The logo is an emerald gate; the product gates
   AI/operator actions. The whole visual language promotes that one idea —
   don't invent a second metaphor.
2. **Color is a semantic map of policy outcomes**, not decoration:
   **emerald = passed / allowed / healthy**, **amber = pending / needs approval
   / caution**, **rose = denied / failed / danger**, **zinc = neutral**. A green
   button and a green "Allowed" chip are the *same* statement. Never color for
   variety; color for meaning.
3. **Two registers, one system: calm console, expressive marketing.** Same
   tokens, type, semantics, and components everywhere. Marketing earns drama
   (the gate device, grain, glow, motion) because it sells; the console is a
   tool operators stare at under stress — it stays calm, flat, fast, legible.
   "In line with marketing" means *adopt the brand + craft*, **not** *import the
   glow*. (§8)
4. **Boring but crafted.** Reach for the dull, proven shape; then spend the
   craft budget on the small things — concentric radii, tabular numbers on live
   counts, real hit areas, specific transitions, handled empty/loading/error
   states. Drama must earn its cost with a product reason + a reduced-motion
   path + a perf check.
5. **Restraint is the brand.** Short motion distances, one gentle ease, nothing
   loops (except the one calm gate pulse). One or two signature surfaces per
   marketing page, never a page of glows. On the console: essentially none.
6. **Dark-native.** The product is a dark UI (`zinc-950` ground). Design for
   dark first; light surfaces are rare inversions.
7. **Accessible by default.** Visible keyboard focus everywhere (global brand
   ring), `prefers-reduced-motion` honored globally, semantic color always
   paired with a label/icon (never color alone), real contrast.

---

## 2. Brand & logo

The mark: an **ink chevron `⟨` + an emerald chevron `⟩`** flanking a vertical
**track of three node-rings** — top/bottom ink, **middle emerald** (a request
passing the gate). Plus a **custom geometric wordmark** "emisar".

| Asset | File | Use |
|---|---|---|
| Icon (square) | `images/brand/emisar-icon.svg` | square `<img>` slots, OAuth pages |
| Wordmark | `images/brand/emisar-wordmark.svg` | wordmark-only contexts |
| Lockup (icon+wordmark) | `images/brand/emisar-logo.svg` | nav, default `<.brand>` |
| Lockup PNG (dark bg) | `images/brand/emisar-logo.png` | JSON-LD `logo` (SERP-safe) |
| Favicon glyph (tile) | `/favicon.svg`, `/favicon.ico` | browser tab |
| App icons | `/apple-touch-icon.png`, `/android-chrome-{192,512}.png` | iOS/Android/PWA |
| OG card | `images/og/emisar-og.webp` | social share |

**Components (reuse — never re-inline the SVG):**
- `<.brand size={:sm|:md|:lg} wordmark?>` — the lockup img (or icon-only). Used in
  every nav/auth/error/oauth shell. White-baked (dark contexts).
- `<.gate_mark animate? class>` — the icon as inline SVG (so it inherits
  `currentColor` for ink + animates). `animate` pulses the three rings
  top→bottom (a request crossing). Anchors the /security architecture diagram.
  **For any "gate moment", reuse this — don't redraw.**

**Logo emerald = `#36E6A5` = `brand-400`.** (The source art shipped a brighter
`#36EFC0`; we unified on `brand-400` so the mark matches every button/chip. If
that's ever revisited it's a one-token change.) Favicon glyph sits on a dark
tile so it reads on any browser tab.

---

## 3. Tokens

### 3.1 Color

**Brand emerald (the one accent + the "pass" semantic).** Defined in
`tailwind.config.js` (`theme.extend.colors.brand`). This is the *only* green —
use `brand-*` for accent, primary action, links, and success/allowed/healthy.

| Token | Hex | Role |
|---|---|---|
| `brand-50` | `#e7fdf4` | faint tints / wash |
| `brand-100` | `#c8fae5` | |
| `brand-200` | `#95f3cd` | |
| `brand-300` | `#57ecb2` | **link / hover-up text** (`text-brand-300`) |
| `brand-400` | `#36e6a5` | **the logo green** — accents, icon tints, focus ring, scan/glow |
| `brand-500` | `#14cf8d` | **primary button fill** (dark `zinc-950` text reads on it; hovers up to 400) |
| `brand-600` | `#05a974` | button active |
| `brand-700` | `#07835b` | |
| `brand-800` | `#0a6749` | |
| `brand-900` | `#0a543c` | |
| `brand-950` | `#032f22` | deep tint backgrounds (`bg-brand-500/10` is more common) |

**Semantic palette** (policy outcomes — Tailwind hues, no brand token needed):

| Meaning | Hue | Typical classes |
|---|---|---|
| pass / allowed / healthy / connected / approved / published | **`brand`** (emerald) | `text-brand-300`, `bg-brand-500/10`, `ring-brand-500/30`, `border-brand-500/40` |
| pending / needs-approval / caution / warning | **`amber`** | `text-amber-300`, `bg-amber-500/10`, `ring-amber-500/30` |
| denied / failed / danger / error | **`rose`** | `text-rose-300`, `bg-rose-500/10`, `border-rose-500/40` |
| neutral / off / muted | **`zinc`** | see below |

> ✅ **Migrated (2026-06-23):** the console runs on `brand-*` — no raw
> `indigo-*`/`emerald-*` classes remain (the marketing demo terminal's deliberate
> `emerald-400` is the only exception). The shared-component **tone vocabulary is
> SEMANTIC** — `:brand` (healthy/pass), `:amber` (pending/caution), `:rose`
> (deny/danger), `:neutral` (identity/metadata) — across
> `chip`/`list_row`/`count_badge`/`summary_stat`/`section_header`. There is **no**
> `:indigo`/`:emerald`/`:default`/`:zinc` tone atom: those were dead/lying aliases
> (two byte-identical greens that painted neutral metadata green, diluting "emerald
> = passed the gate") and are gone. **Color names a MEANING, never a hue or
> convenience** — a metadata label ("You", a scope, the current plan, a reusable
> key) is `:neutral`, not green; green is reserved for a real pass/healthy state
> (trusted, enabled, online, enrolled). **Enforcement:** each component's `attr
> ..., values: [...]` whitelist makes a stray `tone={:indigo}` a compile error
> under `--warnings-as-errors`, and the tone-class clauses carry no catch-all, so a
> computed dead atom raises instead of silently rendering neutral.

**Neutrals (Tailwind `zinc`) — the dark UI scale:**

| Surface | Class | Note |
|---|---|---|
| App ground | `bg-zinc-950` (`#09090b`) | the page |
| Card / panel | `bg-zinc-950/60` over the ground, or `bg-zinc-900/…` | subtle lift |
| Hairline border | `border-zinc-900` (`/80` for softer) | the default divider |
| Heading text | `text-zinc-50` / `text-zinc-100` | |
| Body text | `text-zinc-400` | running copy |
| Eyebrow / meta label | `text-zinc-400` | the canonical small uppercase label (read below) |
| Faint / decorative | `text-zinc-500` / `text-zinc-600` | a divider word ("or"), a purely decorative caption |

> **Contrast (WCAG AA).** `zinc-400` body/intro text clears AA on the `zinc-950`
> ground (~7.8:1); `zinc-500` (~4:1) and `zinc-600` (~2.5:1) do **not**. So reserve
> `zinc-500`/`zinc-600` for genuinely de-emphasized or decorative bits, and use
> **`zinc-400` for any SMALL essential secondary text** — a `text-[10px]`/`text-xs`
> label, scope, count, or timestamp an operator actually has to read. When in doubt
> at a small size, go `zinc-400`.

> **The eyebrow is ONE shape — don't re-tune it per page.** Every small uppercase
> label (a meta-strip key, a section eyebrow like "REASON"/"ARGUMENTS", a stat tile
> label, a card eyebrow) is exactly `font-semibold uppercase tracking-wider
> text-zinc-400` at its role size (`text-[10px]` for meta-strip/tiny keys, `text-xs`
> for section headers). Not `font-medium`, not `tracking-[0.12em]`, not zinc-500/300/200.
> Route through `<.label variant={:eyebrow}>` / `<.meta_field>` / `<.section_header>`
> rather than hand-rolling an `<h3 class="…uppercase…">`, so it can't drift again.
> The only sanctioned exception is a divider word (`or_separator`'s "or"), which is
> connective tissue, not a label, and stays quiet (`zinc-500`, no weight).

### 3.2 Typography

- **Family:** self-hosted **InterVariable** (`100–900`, `priv/static/fonts/`),
  applied on `:root` with `liga` + `calt`. No external font request. Italic cut
  available. (`app.css` top.)
- **Display cut — `.font-display`:** `font-optical-sizing: auto` +
  `font-feature-settings: "cv11" 1` (the **single-story geometric `a`** — the
  typographic signature, less default-Inter) + calt + liga. All marketing
  headings route through it via `<.marketing_heading>`.
- **Type scale** (`marketing_heading_scale/1`; base = `text-balance font-display
  font-bold text-zinc-50`):

  | Scale | Classes | Use |
  |---|---|---|
  | `:display` | `text-6xl md:text-7xl tracking-[-0.035em]` | page H1 hero |
  | `:hero` | `text-4xl md:text-5xl tracking-[-0.03em]` | secondary hero |
  | `:section` | `text-4xl sm:text-5xl tracking-[-0.03em]` | centered section header |

  Negative tracking tightens with size (display tightest). Body copy is plain
  Inter (root), `text-zinc-400`, `leading-8`/`leading-7`/`leading-relaxed`,
  `text-pretty` on paragraphs, `text-balance` on headings.
- **Console page titles** carry `.font-display` at the *console* size — the app
  shell's title is `font-display text-lg sm:text-xl font-bold tracking-tight`. The
  cv11 single-story `a` ties the console to the marketing type signature without
  the big marketing scale or any materiality (calm = small + flat, not a
  different typeface). Section/card headers *within* a page stay plain
  (`text-sm font-semibold text-zinc-100`) — the display cut is for the page title
  only, not every label.
- **Numbers:** live counts / metrics / tables use **tabular figures**
  (`font-variant-numeric: tabular-nums` / `tabular-nums`) so they don't jitter.
- **Mono:** `font-mono` for action ids, code, terminal, runner names.

### 3.3 Space, radius, elevation

- **Radius — concentric:** outer cards `rounded-2xl`; inner elements step down
  (`rounded-lg`, `rounded-md`); chips `rounded`/`rounded-full`; icon tiles
  `rounded-lg`. A child's radius is never larger than its parent's.
- **Section rhythm (marketing):** `py-24 sm:py-32` between sections; content in
  `mx-auto max-w-7xl px-6 lg:px-8`; prose columns `max-w-2xl/3xl`.
- **Elevation = light, not just a box.** Marketing's signature surfaces use
  `.surface-glass` (top sheen + inner highlight + deep soft shadow).
- **Console elevation — "ISLANDS ON BLACK" (shipped 2026-07-03; the P1–P5
  typography pass alone read as "the same" — this is what made the redesign
  VISIBLE).** Three planes, no gray hairline borders on surfaces:
  1. **GROUND** — the work canvas is TRUE BLACK (`<main>` `bg-black` + the faint
     brand top wash); the zinc-950 sidebar/topbar read as separate chrome.
  2. **ISLAND** — every card/panel/table/meta-strip/wizard/pillar lifts onto
     `bg-zinc-900/60 ring-1 ring-white/[0.07]
     shadow-[inset_0_1px_0_0_rgba(255,255,255,0.05)]` (edge-as-LIGHT + a 1px
     inset top highlight). ONE recipe on `<.card>`; LiveTable wrappers and the
     one-off surfaces follow it. In-island hairlines/dividers are
     `border-white/[0.06]` / `divide-white/[0.06]`; recessed in-island bands
     (group headers, output-terminal headers) sit on `bg-black/30`.
  3. **RECESSED / RAISED** — code + terminals recess into `bg-black/30..80`
     insets (+ `ring-white/[0.06]`) INSIDE the lit islands; the ONE anchor per
     page (the approval Command) raises to `bg-zinc-900/[0.85]
     ring-white/[0.12]` with a brighter inset.
  - **Row hovers are a LIGHT wash** — `hover:bg-white/[0.04]` — never a zinc
    fill (dark-on-dark vanishes on the island fill; this exact regression made
    tables read "inert").
  - **Drop shadows stay banned on the console** (unreadable on black; the inset
    top-light IS the elevation) — the one exception is a floating layer
    (popover/menu/account-switcher), which must be OPAQUE (`bg-zinc-900`) +
    `ring-white/10` + `shadow-xl shadow-black/60` so content never ghosts
    through. Interactive control chrome (inputs, icon buttons, dashed add-rows)
    deliberately KEEPS gray borders — border = control, ring-light = surface.
- **Icons:** Heroicons via `<.icon name="hero-…" />` (outline 24 default; `-solid`,
  `-mini` 20, `-micro` 16). Sizes `h-4 w-4` (inline), `h-5`, `h-6` (feature).

### 3.4 Materiality primitives (marketing signature — `app.css`)

Decorative, non-animating, `aria-hidden`, used **sparingly** (1–2 per page):
- `.grain` — SVG fractal-noise overlay (opacity `0.04`, `mix-blend overlay`) so
  flat dark panels don't read digitally flat. Absolute, inset-0 layer.
- `.glow-emerald` — soft brand-green radial bloom for hero/CTA moments.
- `.surface-glass` — the lit-surface card (sheen + inner highlight + deep shadow).
- Backdrops: `.hero-grid` (fading dotted), `.contract-grid` (blueprint lines),
  `.hero-glow` (emerald radial). **Marketing only — keep them off the console.**

### 3.5 Motion (`app.css`)

- **One easing:** `cubic-bezier(0.16, 1, 0.3, 1)` (gentle expo-out). Short
  distances (`12–16px`). Standard durations `0.7s` (reveal/rise), `~0.2s`
  (hover/state).
- `.rise-1…5` — pure-CSS staggered hero assembly (delays `0/.08/.16/.24/.34s`);
  no-JS safe.
- `[data-reveal]` under `.js-reveal` — on-scroll reveals via `reveal.js`
  (IntersectionObserver adds `.is-in`). **Progressive enhancement:** hiding only
  engages once JS adds `.js-reveal`, so crawlers/no-JS see everything.
- `.gate-dot`/`gate-pulse` — the calm gate device pulse (the one loop).
- `.scan-sweep` — single sweep across a decision point (`<.scan_line animate>`).
- **Reduced motion is non-negotiable:** a global `@media (prefers-reduced-motion)`
  neutralizes animations/transitions; every signature also lands at its lit end
  state explicitly. Console hover-lifts/pings/spins are caught by the same global
  rule. Never ship motion that isn't reduced-motion safe.

### 3.6 Global a11y tokens (already app-wide — marketing **and** console)

- `:focus-visible` → `outline: 2px solid #36e6a5` (`brand-400`), `offset 2px`,
  `radius 3px`. Keyboard-only. **Do not override per-component** — let the global
  ring show.
- `::selection` → `brand-400 / 30%`.

---

## 4. Components (reuse before you build)

**Iron rule (`.agent/rules/ui-shared-components.md`): one shared component per UI
shape.** Never hand-roll a card / chip / banner / button / empty-state / page
width / stat. Grep `core_components.ex` first; extend the primitive if it's
genuinely missing (then it's shared, not one-off).

### Brand / gate
`brand`, `gate_mark`.

### Marketing kit (the Gate primitives — `core_components.ex`, marketing-only)
- `gate_frame state={:pass|:pending|:deny|:neutral}` — brackets content like the
  logo (state-tinted border).
- `scan_line animate? state` — the decision-point hairline + optional sweep.
- `state_chip state={:pass|:pending|:deny} label?` — the semantic outcome chip
  (thin wrapper over `<.chip>`; default words Allowed/Approval/Denied).
- `code_block` — the one framed code/terminal surface.
- `marketing_heading tag scale class` — the display type scale (§3.2).
- `marketing_button size icon external? block?` — brand-filled CTA
  (`active:scale-[0.96]`, trailing-icon nudge on hover). **Primary marketing CTA
  is always "Start free."**
- `marketing_nav`, `marketing_footer`, `marketing_cta`, `marketing_nav_link`,
  `marketing_mobile_link`, `external_link`.

### Shared chrome & data (used by the console — `core_components.ex`)
- `button` (tones: primary/caution/danger + link tones), `icon_button`, `menu`.
- `chip`, `risk_pill`, `status_badge` — semantic status (see §3.1; success
  variants currently `emerald-*` → migrate to `brand-*`).
- `input`, error/notice/`alert`/flash — forms + feedback (rose error tier).
- `stat` (tile) · `summary_band` (strip) · `meta_strip` — the stat trio; pick by
  shape (see ui-shared-components rule). `summary_dot` (emerald/amber/rose).
- `subscription_banner`, `modal`, typed-confirm dialogs.
- **`EmisarWeb.LiveTable`** — every list/table (stateless, URL-driven). Never
  hand-roll pagination/sort/filter.

---

## 5. Patterns

- **Page width:** `mx-auto max-w-7xl px-6 lg:px-8` (one shared shape — don't
  invent widths).
- **Policy-outcome color discipline:** any allow/approve/deny state → the §1.2
  palette, always with a word or icon, never color alone. A comparison/feature
  table full of rose reads as fear — competitor "no" stays muted `zinc`, not rose.
- **Cards:** `group rounded-2xl border border-zinc-900 bg-zinc-950/60 p-6/8
  transition hover:border-brand-500/50`, an icon tile
  (`bg-brand-500/10 text-brand-400 rounded-lg`), title `text-zinc-50
  group-hover:text-brand-300`, body `text-zinc-400`, a "Read it →" affordance
  with a `group-hover:translate-x-0.5` arrow.
- **States are part of the component, not a later pass:** every list/panel/form
  ships empty, loading, error, and (where relevant) offline states. The
  `/ux-designer` hat will ask for them.
- **Forms:** `to_form/2` + CoreComponents inputs; show changeset errors inline
  (rose); the context exposes `change_*` builders, the LiveView owns
  `to_form`/`phx-change`/validate.
- **Tables/lists:** `LiveTable` + `stream/3` (IL-18); tabular-nums on numeric
  columns; calm row hover; real empty state.

---

## 6. Marketing ↔ Console: the two registers

| | Marketing (`controllers/marketing_html/`) | Console (`live/**`) |
|---|---|---|
| Job | sell / explain → convert | operate under stress → clarity |
| Tone | expressive, signature, crafted drama | calm, flat, fast, dense, legible |
| Accent | `brand` emerald | `brand` emerald (after migration) |
| Type | full `.font-display` scale | quiet semibold/bold `tracking-tight`; display cut sparingly |
| Materiality | grain / glow / glass / blueprint backdrops | **none** — hairline borders + faint fills |
| Motion | rise + reveal + gate device + scan | micro only (calm hover, state transitions); no reveals/glow/loops |
| The gate device | hero/diagram signature | not in workflows (a brand moment, not chrome) |
| Layout | wide hero sections, `py-24/32` rhythm | dense app shell, tables, panels, toolbars |

**Shared across both (the throughline that makes them one product):** the
`brand` emerald, the pass/pending/deny semantics, Inter, the `core_components`
primitives, the global focus ring + selection, concentric radii, tabular
numbers, real states, reduced-motion discipline.

So **"bring the console in line with marketing" = adopt the shared row + the
craft**, and **resist** importing the expressive row. The console should look
like it was made by the same team — not like a landing page.

---

## 7. The console migration plan (the actionable part)

**Objective:** the operator console reads as the same brand as the marketing
site — emerald, type, semantics, crafted detail — while staying a calm tool.

### 7.1 Token migration (mechanical, do first — low risk, high coherence)
1. **Accent / primary / links: `indigo-*` → `brand-*`.** Grep
   `core_components.ex`, `live/**`, layouts for `indigo` (e.g. `auth_layout`
   `from-indigo-950`, any `text-indigo`/`bg-indigo`/`ring-indigo`/focus). Replace
   with the `brand` equivalent. There is **no** indigo in the target system.
2. **Green semantic: `emerald-*` → `brand-*`.** Unify the success/pass/connected/
   approved/published green onto `brand` (`status_badge`, `button` primary
   `bg-emerald-500 → bg-brand-500`, `notice` success, `summary_dot(:emerald)`,
   menu/icon-button "success", the auth-layout check bullets). `brand-400 ≈
   emerald-400`, so it's visually safe and kills the two-greens smell.
3. **Keep** `amber` (pending/caution), `rose` (danger/error), `zinc` (neutral)
   — they're already the target. Keep the global focus ring + selection.
4. **Verify:** after the sweep, `grep -rE 'indigo-|emerald-' lib/emisar_web`
   should return only deliberate exceptions (the marketing demo terminal's
   `emerald-400` accents are fine; document any kept emerald with a why).

### 7.2 Component craft pass (the "feels like the same team" work)
Run the `make-interfaces-feel-better` micro-craft on the console shells: concentric
radii, tabular-nums on every live count (runs, runners, audit), real hit areas
(≥40px), specific transitions (not `transition-all`), calm row hover, handled
empty/loading/error/offline states. Reuse the shared `stat`/`summary_band`/
`status_badge`/`chip`/`button`/`LiveTable` everywhere — replace any hand-rolled
card/chip/stat with the shared primitive.

### 7.3 Priority order (highest-traffic operator surfaces first)
1. App shell / nav (`<.brand>` already new) + dashboard (CON-001).
2. Runs list + run detail (the live-output surface) (CON-005/006).
3. Runners list + detail + install wizard (CON-002/003/004).
4. Approvals + policy editor + packs (GOV-*) — the gate UIs; lean on the semantic
   palette hard here (allow/approve/deny is the whole screen).
5. Settings (team/SSO/SCIM/billing/profile) (TEAM/BILL).
6. Auth flows (`auth_layout` — kill the indigo gradient) (AUTH-*).

### 7.4 Do NOT
- Don't import `.grain`/`.glow-emerald`/`.surface-glass`/`.hero-*`/the gate
  device into console workflows. Calm is the console brand.
- Don't add scroll reveals or the rise stagger to the app.
- Don't touch the marketing demo terminal styles or the marketing-only kit.
- Don't introduce a third green or a new accent hue.

---

## 8. Quick do / don't

✅ One green (`brand`). ✅ Color = policy meaning + always a label. ✅ Reuse a
shared component. ✅ Tabular numbers on live counts. ✅ Concentric radii. ✅
Reduced-motion safe. ✅ Calm console, expressive marketing. ✅ Visible keyboard
focus (global ring).

❌ `indigo-*` or raw `emerald-*` (use `brand`). ❌ Color for variety. ❌
Hand-rolled card/chip/stat/table. ❌ Glow/grain/glass/gate-device in the console.
❌ Motion that isn't reduced-motion safe. ❌ A table full of rose. ❌ A second
accent hue or a second green. ❌ Overriding the global focus ring.

---

## 9. Source of truth (read the code, not just this)

- **Tokens:** `assets/tailwind.config.js` (the `brand` scale; everything else is
  Tailwind default — `zinc`/`amber`/`rose`/Heroicons).
- **CSS layer:** `assets/css/app.css` (`@font-face` Inter, `.font-display`, the
  a11y tokens, materiality primitives, all motion keyframes).
- **Components:** `lib/emisar_web/components/core_components.ex` (the kit + shared
  chrome). `EmisarWeb.LiveTable` for lists.
- **Logo assets:** `priv/static/images/brand/`, favicon family at the static root.
- **Engagement history + locked decisions:** `[[marketing-redesign-gate-direction]]`
  (memory). **Component/shape rules:** `.agent/rules/ui-shared-components.md`.
- **The console IA/UX doctrine — page archetypes, the component-first law, the ONE tone
  system, confirm ladder, state matrix, density budgets:** `.agent/rules/console-ux.md`.
  This file is the visual layer; that one is the structural layer. Read both before any
  console change.
- **The frontend execution hat:** `/frontend` skill (LiveView/HEEx/Tailwind
  rules + the make-interfaces-feel-better pass). **Art direction:**
  `/creative-director`.
