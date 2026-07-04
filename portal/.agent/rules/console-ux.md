# Console UX doctrine — pages, components, tones, states

> The IA/UX layer for the **operator console** (`live/**` + the auth pages). The visual
> layer (tokens, type, color semantics, motion) is `design-system.md` ("The Gate") — read
> both before touching a console page. Marketing keeps its own register; it gets an
> enforcement pass against §2 later.
>
> Source inventory + extraction plan: `.agent/design/console-inventory.md` (local working
> doc). This file is the durable doctrine that survives it.

---

## 1. The component-first law

**A UI shape that appears on 2+ pages is a shared component. A one-off must earn its
existence with a why-comment.** This is the whole strategy: pages are *compositions* of
shared shapes, so a page can be rewritten (by a human or an LLM) without re-inventing —
or subtly forking — the design. Consistency lives in the kit, not in per-page discipline.

- Before writing markup: grep `core_components.ex` for the shape. Extend the primitive
  (a new attr/variant/slot) rather than fork it; if it's genuinely missing, extract it —
  **and migrate every existing instance in the same change** (greenfield, IL-11).
- A page-local function component is legitimate only when it *composes shared parts* into
  page-specific domain meaning (e.g. an approval `decision_panel`). It is never legitimate
  for a generic shape: card, header, callout, badge, dot, pill, code block, disclosure,
  avatar, steps, meta line — those are kit shapes by definition.
- Never rebuild a shared component's classes on a raw element ("it needed one more class"
  → add the attr to the component). Raw `<button>`s wearing `<.button>` recipes, raw pills
  beside `<.chip>`, and hand-rolled `<h3 class="…uppercase…">` headers are the banned smell.
- Specialized components (e.g. domain banners) are **thin wrappers** over a primitive:
  they map domain state → tone/copy and add nothing visual of their own. A wrapper with
  its own class table is a fork.

## 2. One tone system

Every component color attr uses ONE vocabulary — the hue atoms of design-system §3.1,
with meaning assigned at the call site:

| Atom | Meaning at call sites |
|---|---|
| `:neutral` | identity, metadata, off, muted |
| `:brand` | pass / allowed / healthy / connected / primary action |
| `:amber` | pending / needs-approval / caution |
| `:rose` | denied / failed / danger / error |

- Attr name is `tone` for color meaning; `variant` is reserved for *structure*
  (`:primary/:secondary/:ghost`, `:boxed/:bare/:strip`). Never encode color in a variant.
- `:pass | :pending | :deny | :neutral` stays **only** on policy-verdict components
  (`status_tone/1`, `state_chip`, LiveTable `card_accent`) — it names a verdict, not a hue.
- Enums are **atoms**, never strings (`variant={:primary}`, not `"primary"`); every enum
  attr carries `values:` so a stray atom is a compile error (no catch-all clauses).
- No dead aliases: one class ramp per meaning. (`button "success"` ≡ `"primary"` and
  `notice :info` ≡ `:success` are the known corpses — collapse on contact.)
- `offline_notice`'s `:info/:caution/:critical` and `empty_state`'s `:zinc/:danger` map
  onto the four atoms when touched.

## 3. Page archetypes

Seven archetypes cover the console. Every page declares one; a page that fits none is a
product-design conversation, not a new layout. **One feature = one width family** — its
list, detail, and forms use the archetype widths below, never per-page drift.

| Archetype | Width | Skeleton (top → bottom) | Reference |
|---|---|---|---|
| **List** | `:full` for a DENSE columnar table (many `<:col>`s — Runs, Audit); `:table` for a CARD/grouped list or panel list (`<:item>` rows, sibling panels — Runners, Approvals, Packs, Agents) so single-value rows don't stretch thin | shell title + `:actions` primary CTA · `page_intro` + `doc_link` · optional `summary_band` · optional `pivot_chip`s · ONE LiveTable (filters from `Query.filters/0`) · 4-state empty slot (§4) | RunsLive |
| **Detail** | `:detail` | `detail_header` (back · entity title · `:actions`) · `meta_strip` leads, Status first · conditional callout stack · sibling content cards · danger zones last | RunDetail |
| **Editor** | `:detail` | `detail_header` + Cancel in header · the editing surface · Save/primary action in ONE place (the surface's footer row) · inline errors · no silent data loss on navigate | RunbookEditor (shape, not details) |
| **Create flow** | `:form` | own `/new` route · single `panel` form · privilege choices as `choice_cards` · **in-page success step** (do-again / back-to-list) — never flash-and-redirect | Team invite |
| **Settings** | `:settings` | `page_intro` + `doc_link` · sibling `panel` islands, one per concern — never a label-left/content-right divider table | SSO :new/:edit |
| **Wizard** | `:form` | one guided surface · one primary action per step · live wait states with escalating troubleshooting · page-advance keyed to the specific entity it created | RunnerInstall |
| **Wait-room** | auth layout / `:form` | status_dot + what-happens-next promise · live resolution · the promise must survive a dropped socket (reconnect note) | SSOPending |

Structural rules that ride along:

- **Sibling islands.** Co-equal concerns are sibling `card`/`panel` islands — never
  card-in-card, never one mega-card, never fully flat. No two stacked competing headers:
  dedupe a title+subheading pair that says the same thing twice.
- **A titled surface is a `panel`** (title · optional subtitle · optional right-side
  annotation · `:actions`); a bare surface is a `card`. A hand-rolled header row inside a
  `card` is banned — that's `panel` (with `padding={:none}` for `divide-y` list bodies).
- **Island-header grammar (design-review R2).** Two registers, chosen by what the island
  IS, never by taste: an **eyebrow** (`title_variant={:eyebrow}` on `panel` — the xs uppercase
  zinc-400 atom) heads a piece of the RECORD — a
  read-only field or fragment of the entity (Reason, Arguments, Payload, Changes, Actor /
  Subject, What this does); a **title-case display header** (`panel`'s default) heads a
  surface with its own job — interactive (Decide, an editor) or a navigable collection
  (Recent runs, Advertised actions, Group mappings). The 10px uppercase atom is the
  *field-label* level (`meta_field`, an id line INSIDE a card) — it never heads an island.
  Eyebrows are always zinc-400: tone lives in the content (chips, diff rows), never the
  header — three colored eyebrows in one island read as three competing accents.
  (`code_panel`'s label was deliberately REGRADED to the 16px title tier — a command
  inset is the page's anchor artifact, not a record fragment; see the why-comment at
  its definition.)
- **Detail meta leads.** A detail page opens with `meta_strip`, Status field first;
  em-dash (muted, own span) for absent values.
- **Filters are all visible — never hidden behind a "More filters" disclosure — and
  flow INLINE by default.** A list's filter bar shows every filter at once. The default
  `filter_layout={:inline}` flows them in ONE wrapping row of equal-width compact
  controls (`flex flex-wrap`, each `w-full sm:w-48`): don't newline a handful of filters
  into a wide grid for no reason. Folding "niche" filters behind a disclosure hides what
  the operator is looking for and (with `display:contents` on a `<details>`) renders as a
  broken floating layout. The clear affordance is a labeled "× Clear filters" link shown
  only when a non-default filter is active (default ≠ active). LiveTable owns this.
  - **Opt into `filter_layout={:stacked}` ONLY when a filter dynamically reveals a
    dependent control that must sit beside it** (the audit Actor/Subject kind pickers
    reveal a value dropdown). Stacked is a two-column grid (`grid-cols-1 sm:grid-cols-2`)
    driven by each `%Filter{}`'s `span`: `:half` flows, `:full` takes a row, and
    `:row_start` is a half-width control forced to column 1 so its revealed value picker
    pairs in the cell beside it. A kind picker's title is "<X> type" so it doesn't collide
    with the "<X>" value picker next to it. Never make a filter double-width just to fill
    space — that was the exact "don't make them double width" correction.
- **Settings never embed in operational pages** without a PM decision — the current three
  (2FA/SSO toggles on Team, grant cap on Approvals, SIEM tokens on Audit) are grandfathered
  until that pass; do not add a fourth.
- **The Settings IA (2026-07-04 restructure).** The nav's Settings group is exactly TWO
  items: **Team** (the people + access hub — the roster LEADS the page; the Security
  posture rows (2FA, SSO) follow below it as the rare-touch footer concern, and they are
  SSO's one console door) and **Billing**. Every credential surface lives behind its
  OWNING page as a title-row door, never a nav item: runner keys → Runners, agent keys →
  LLM agents (+ /connect create flow), SIEM tokens → Audit. Don't re-add nav items for
  sub-features; don't move the roster back below account config.

## 4. States are part of the page, not a later pass

Every page ships the full matrix; a missing state is a bug:

- **Loading:** `loading_state` on the dead/connecting render — never bare "Loading…" text,
  never a flash of the empty state (don't render "No X yet" before the connected load).
- **Load error:** an explicit danger `empty_state` whose copy says *this is a read
  failure, not an empty list*. **Silent degrade-to-empty is banned** — on a security
  product, a failed read must never look like "nothing happened". Applies per-section on
  multi-section pages (a failed sidebar read gets its own error state, not `[]`).
- **Empty:** two distinct states — *account-empty* (pitch + CTA into the setup path) vs
  *filter-empty* (quiet one-liner; the filter bar stays rendered and live).
- **Permission:** a gated control is hidden (or replaced by a one-line "why not" note when
  its absence would confuse); the handler re-gates regardless (IL-15). Plan-locks and
  permission-locks are different messages — don't conflate them.
- **Offline/queued:** anything runner-dependent states what happens while the runner is
  offline (queue vs refuse), consistently with its siblings.

## 5. Confirm-severity ladder

Confirm friction scales with blast radius; the copy states the **consequence**, never
"are you sure?".

| Tier | Mechanism | When | Examples |
|---|---|---|---|
| **Typed** | `confirm_dialog` (type the token) | irreversible AND high blast radius, or credential/identity-destroying, or fleet-wide adoption | delete runner/provider, remove member, revoke auth key, **pack trust AND reject** (trust adopts code fleet-wide — it is not the lesser action) |
| **Native** | `data-confirm` | disruptive but reversible or self-healing | suspend/reinstate, disable runner, cancel run, rotate key, re-run runbook, enforcement toggles |
| **None** | — | additive/creative actions, navigation | create, invite, save draft |

One ladder, no per-page taste: if two pages confirm the same class of action differently,
one of them is wrong.

## 6. Density budgets

- **One primary job above the fold.** The page's reason-to-exist (the table, the form,
  the decision) starts above the fold on a 13" laptop; preamble (intro, banners, meta)
  must not push it off. Budget: intro + ≤2 conditional banners + one summary strip.
- Attention stacks (dashboard triage) are the documented exception — and even there,
  banners collapse when not actionable (no green "all good" boxes, ever — silence IS the
  confirmation; a success box exists only as a direct *action result*, e.g. a test-
  connection probe).
- **Type floor `text-[10px]`** (design-system's meta-strip key size). `text-[9px]` is
  banned. If it only fits at 9px, it doesn't fit — restructure.
- An editing card stacks **≤6 inputs**; past that, split into islands or progressive
  disclosure (`disclosure` component — advanced/optional settings collapse).
- A row carries **≤4 chips**; past that the chips aren't statuses anymore, they're a
  detail page trying to happen.

## 7. Graduated house rules (formerly memory-only — now doctrine)

1. **No green confirmation box.** A callout earns its space only when actionable
   (warning/error/next-step). Healthy state renders as *absence* — collapse
   `if ok → green else → amber` to `:if={problem?}`.
2. **Choice→consequence editors.** A control whose settings produce a real consequence
   renders that consequence as the color-coded verdict (warning-only); option cards argue
   toward it; **selection state stays neutral** — a risky option must never wear the safe
   hue.
3. **Empty placeholder = muted em-dash** (`text-zinc-500`) on its OWN span — never the
   value's bright/mono styling; adjacent no-value cells match.
4. **Default value ≠ active filter.** A control at its default never renders as
   applied (no highlight, no clear-×). Model `default` on the `%Filter{}`; value ==
   default is baseline.
5. **Inline form errors.** A fixable submission error renders at the input, never
   redirect+flash (`.agent/rules/inline-form-errors.md`). This includes OTP/code entry —
   a wrong code is an inline `code_input` error, not a flash.
6. **Browser-owned element state is server-owned in LiveView.** `<details open>`,
   dialog visibility, panel collapse — own it in an assign and always re-render, or the
   next patch snaps it shut. The `disclosure` component encapsulates this; never a raw
   `class="hidden"` + `JS.show` for state that must survive a re-render.
7. **Page-advance keys to the specific entity.** A wizard auto-advancing on a live event
   matches the exact token/row it created (bootstrap key id, request id) — never an
   account-wide event.
8. **Same concept picked/rendered in 2+ surfaces → ONE component** (RunnerScope
   precedent, generalized by §1). This includes *logic* twins: UA parsing, role labels,
   status derivation — one module, not per-page copies.
9. **OTP/code entry is `code_input`** — every code-typing surface (magic link, TOTP
   enroll/confirm, email step-up) uses the boxes; a plain text field for a code is a bug.
10. **Secrets reveal once, through `secret_reveal`** (or its recovery-codes variant) —
    one shape for "copy this now, it won't be shown again", never a bespoke amber box.

### 7.1 Create-flow footer + the ONE back affordance (design-review R1)

- **A form's footer groups its buttons** — primary + quiet cancel side by side
  (`simple_form`'s actions row is `flex gap-3`, never `justify-between`): a pair flung
  to opposite edges loses its association and puts Cancel where the primary
  conventionally sits. A single full-width button (auth pages) still spans naturally.
- **ONE back affordance: `<.back_link>` in the shell `:title`, above the page's job.**
  Never a boxed "← Back to X" button in `:actions`, never an in-body ghost arrow link.
  The shell title is the page's JOB ("Invite a member", "Connect a runner"), not the
  parent section's name; a panel below it never re-titles the page with a near-synonym.

## 8. The kit is the contract

- The shared kit lives in `core_components.ex` (+ `EmisarWeb.LiveTable`,
  `EmisarWeb.RunnerScope`); the census + extraction backlog live in
  `.agent/design/console-inventory.md` §3–4. Phase 0 extractions (callout, panel-header
  unification, `code_panel`, `status_dot`, `disclosure`, `choice_cards`, `avatar`,
  `steps`, `meta_line`, `link_card`, recovery-codes, `mfa_enrollment`, …) land as focused
  commits, each migrating all call sites.
- **The design gate:** a console-touching task is done only after a desktop + mobile
  screenshot of the changed surface is reviewed against this doctrine and the design
  system (rebuild the :4010 stack first — a release image needs `docker compose build
  portal`, not restart).
- When a rule here is corrected or extended by the user, update THIS file in the same
  change (taste pipeline) — this doctrine is append-don't-rewrite, like the AGENTS.md
  house opinions.
