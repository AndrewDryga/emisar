# Console UX doctrine — pages, components, tones, states

> The IA/UX layer for the **operator console** (`live/**` + the auth pages). The visual
> layer (tokens, type, color semantics, motion) is `design-system.md` ("The Gate") — read
> both before touching a console page. Marketing keeps its own register; it gets an
> enforcement pass against §2 later.

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
- **Button chrome is for an ACTION; navigation is a LINK.** A filled/tinted/ringed
  button (any `<.button>` variant, or a hand-rolled button-SHAPED span) means "this
  *does* something" — submits, mutates, opens a flow. Moving to another page is a
  `<.link>` styled as the house nav affordance: brand text + `cta_arrow`, at the
  content baseline. Make a link **prominent by placement and the brand hue**, never by
  wrapping it in button chrome — a button-looking nav link reads as a form submit and
  is the smell (the dashboard pillar SSO action ping-ponged subtle-link → button-chip →
  link before this landed). A stat tile / pillar whose whole surface is already the
  `<.link>` carries its forward action as this inline brand line, not a nested chip.
- `:pass | :pending | :deny | :neutral` stays **only** on policy-verdict components
  (`status_tone/1`, `state_chip`, LiveTable `card_accent`) — it names a verdict, not a hue.
- **Ordinary authoring selection stays neutral.** A selected default, radio card,
  or option is not a pass/allowed verdict: distinguish it with a check or filled
  radio plus neutral surface/ring contrast. A neutral checked checkbox uses a
  mid-tone zinc fill with a high-contrast check; a near-white fill that erases
  the checkmark is not a legible selected state. Semantic color is earned only
  when the selected fact itself means pass, pending, or deny; keyboard focus
  may still use the brand focus ring.
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
| **List** | `:full` for a DENSE columnar table (many `<:col>`s — Runs, Audit); `:table` for a CARD/grouped list or panel list (`<:item>` rows, sibling panels — Runners, Approvals, Packs, Agents) so single-value rows don't stretch thin | shell title + `:actions` primary CTA · `page_intro` + `doc_link` · one contiguous attention-spine slot · ONE LiveTable (filters from the owning context's `<schema>_filters/0` — a deep-link pivot is a REAL filter reading active in the bar, never a chip; `pivot_chip` is DELETED) · 4-state empty slot (§4) | RunsLive |
| **Detail** | `:table` — the SAME width as the list it's reached from, so the header never jumps (run/runner/approval/audit details all converted) | `detail_header` (back · entity title · `:actions`) · NAKED meta row on the canvas, Status first (one flex row at sm+, 2-col grid on phones — no `meta_strip` island); **a qualifier inside a meta VALUE (source kind, client version, group) is dim inline type — bright value then `· qualifier` in zinc-500 (run detail's "Dispatched by" is the template), NEVER a filled chip riding the value; chips mark a row/card's STATE ("no 2FA", "current"), not a value's metadata. A status field renders the NORMALIZED state the page leads with, never a raw DB status that contradicts the verdict (lapsed-but-unswept approval = expired, not pending)** · conditional attention stack (tight `space-y-3` group inside the page's `space-y-12` wrapper) · canvas sections (`section_header`) · artifacts as `code_panel`-framed boxes · danger zones last | RunDetail, RunnerDetail |
| **Editor** | `:table` — same rule as Detail: the list's width | `detail_header` + Cancel in header · the editing surface (repeating units = naked forms under `STEP N` keys with hairlines, never card washes) · Save/primary action in ONE place (the surface's footer row) · inline errors · no silent data loss on navigate | RunbookEditor |
| **Create flow** | `:form` | own `/new` route · single `panel` form · privilege choices as `choice_cards` · **in-page success step** (do-again / back-to-list) — never flash-and-redirect | Team invite |
| **Settings** | `:settings` | `page_intro` + `doc_link` · NAKED sibling `<section>`s, one per concern, each headed by `section_header` (title/subtitle/actions) — panels are DEAD (§8.1); never a label-left/content-right divider table | Profile, SSO :new/:edit |
| **Wizard** | `:form` (`:detail` with a rail) | one guided surface · one primary action per step · live wait states with escalating troubleshooting · page-advance keyed to the specific entity it created · a wizard carrying a supporting rail (trust facts, resources) goes two-column at `lg` — task left, reading right, separated by AIR (a wide gap), never a vertical rule (vertical hairlines are shell chrome; content hairlines are row-lattice grammar only) — and runs `:detail`, never a `:form` tower beside dead space | RunnerInstall |
| **Wait-room** | auth layout / `:form` | status_dot + what-happens-next promise · live resolution · the promise must survive a dropped socket (reconnect note) | SSOPending |

Structural rules that ride along:

- **Complex editors follow operator decision order.** Identity and intent precede
  workflow; action and target precede version pins and stable identifiers;
  runtime-relevant controls stay visible beside the behavior they qualify; and a
  review rail follows the primary workflow when stacked. Preserve the complete
  model through local disclosures instead of deleting features. See
  `design-complex-editors-follow-decision-order.md`.
- **Multi-target scope stays one control in an overview row.** Its stable-height
  trigger summarizes selection and its menu owns both adding and removing.
  Never stack selected target cards above a second picker. An unresolved saved
  target stays human-readable, visibly unavailable, and removable even when the
  current catalog is empty.
- **The attention spine owns remedies.** Page-level actionable notices sit together between
  the intro and the summary/list, never on opposite sides of counters or filters. If a
  notice tells the operator to run a command, copy a secret, or take another concrete
  next step, that payload renders inside the same spine. A sibling alert + code
  panel reads as two unrelated events. Multiple notices keep 24px between them, then the
  stack leaves a larger 40px exit gutter after whichever notice renders last so it does
  not run into the counter, filter, or content region below. Do not put identical bottom
  margin on every notice: inter-alert rhythm and post-alert rhythm carry different
  hierarchy. The same remedy keeps one tone across list and detail pages; stronger color
  is earned by a different consequence, not by the same upgrade action carrying a
  stricter version label.
- **A canvas `:cards` list carries `divide-y` only — no top `border-t`.** The between-row
  hairline is row-lattice grammar; a `border-t` at the top of a headerless list is an
  orphaned rule that reads as a separator under a column header that isn't there (esp.
  above a group header — "default · 1 runner total"). Only a real header row above the
  body earns the top rule. `wrapper_class="divide-y divide-zinc-800/70"`, never
  `… border-t border-zinc-800/70`; the audit list is the reference.
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
| **Typed** | `confirm_dialog` (type the token) | irreversible AND high blast radius, or credential/identity-destroying | delete runner/provider, remove member, revoke agent key, **reject pack** |
| **Plain modal** | `confirm_button` (OUR styled modal, no typing) | every OTHER dangerous/consequential action — disruptive but reversible or self-healing | disable runner, suspend/reactivate member, revoke grant/token, rotate key/SCIM token, disable directory sync, delete group mapping, cancel run, reset 2FA, sign-out (self/others), regenerate recovery codes, remove ruleset/step; **pack trust** = the `tone={:amber}` variant (a caution-approve, not a destruction) |
| **None** | — | additive/creative actions, navigation | create, invite, save draft |

**A dangerous action NEVER uses the native browser `data-confirm`** (the ugly OS dialog, inconsistent, un-styleable). It's `confirm_button` (plain modal, drop-in for data-confirm) or a typed `confirm_dialog`. `tone` on `confirm_button` colors the TRIGGER (`:rose`/`:amber`/`:neutral`); the modal's Confirm is always toned so it never looks like Cancel — a `:neutral` low-key trigger (suspend, rotate) still opens a rose confirm. The remaining native `data-confirm` holdouts are NON-button patterns pending a bespoke pass — the two enforcement `<.switch>` toggles (require MFA / require SSO), the role-change `<.menu_item>`, and the two form-submit run guards (dispatch, run runbook).

One ladder, no per-page taste: if two pages confirm the same class of action differently,
one of them is wrong.

**Keyboard contract.** A typed confirmation is one form: its exact token match enables
the Confirm submitter, and Enter in the input runs the same action as clicking Confirm.
Before the match, the disabled submitter keeps both paths inert. Plain confirmation
modals have no input and remain click-only; opening one must not turn Enter elsewhere
on the page into acceptance.

**The dialog's LOOK is the calm note grammar, not an alarm wall.** A `confirm_dialog` is a
NEUTRAL raised surface (`bg-zinc-900 ring-white/10` — the console dropdown recipe), and its
header IS a `<.status_note tone={:rose} primary>` — a bare toned icon, a **zinc** title, a
**zinc** body. The destructive tone (rose) lives on exactly two things: that icon and the
Confirm button. NEVER wash it into a tone-colored container border, a rose title, or
rose body text (the old delete modal did all three — the user's "not inline with our
design"). Entity names in the body are neutral-bright (`text-zinc-200`), never `text-rose-100`.
The danger reads from the icon + the button + the consequence copy — the surface stays calm.

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
- **A row shows facts the operator ACTS on or identifies by — never system constants.**
  A value that's the same on every row and that no one here manages (the agents keys'
  fixed `actions:read`+`actions:execute` MCP scope pair) is noise wearing a chip;
  delete it and spend the space on an identifying fact instead (the key's OWNER —
  whose credential is this — leads the meta line). Sweep: any chip/meta segment whose
  value is invariant across the account's rows.

## 7. Graduated house rules (formerly memory-only — now doctrine)

1. **No green confirmation box.** An attention block earns its space only when actionable
   (warning/error/next-step). Healthy state renders as *absence* — collapse
   `if ok → green else → amber` to `:if={problem?}`. **The same test applies to
   every tone:** a contained box holds a *functional* payload (a secret + its copy/ack
   or a form), while operational alerts use the naked icon-capped spine. A
   passive caveat ABOUT an adjacent control may use the naked status-note grammar;
   a one-time credential, blocked action, or state requiring a next move is an
   alert and gets the spine. Neither becomes a ringed island that outshouts the
   artifact it describes.
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
   redirect+flash (`.agent/kb/rules/elixir-inline-form-errors.md`). This includes OTP/code entry —
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
11. **Compound identities use two type tiers when the field has vertical room.** The
    accountable person is the primary line in the normal value color, using a
    nonblank full name and falling back to email; the API key, client, or channel is
    a second muted line. Do not spend fixed-column width on connective prose such as
    `via` when position and color already express the relationship. A compact source
    badge shows icon + accountable person only because its icon already carries the
    channel; channel text is only the fallback when no person resolves.
12. **Dense entity facts share one aligned spacing grammar.** Once the primary
    identity is established, secondary forensic facts use one label/value grid, one
    label track, text tier, line height, minimum row height, and row gap. Copy and icon
    buttons fit inside that height instead of making their row taller. Labels top-align
    when a value wraps; only an intrinsically centered control row opts into centering.
    Do not alternate icon-only rows, prose rows, ad-hoc margins, and an internal divider
    inside one compact record. Bound long provenance values so they cannot set the
    width of a relationship track.
13. **Mixed-density table rows align the scan line, then preserve hierarchy.** The
    row grid uses `items-start`; Event/Actor/Target primary values share one font size
    and line height, while supporting IP/When metadata may use a smaller font on the
    same line height. Every secondary line shares one smaller metric pair. Alignment
    comes from the common top edge and line box, not from making every column equally
    loud.
14. **One metadata group has one value typography and tone contract.** Labels may
    use a smaller label tier and machine values may change font family, but every
    peer value in one header strip or fact group keeps the same font size, line
    height, and foreground tone. Use a muted tone only for genuinely secondary or
    missing content; a copy button or monospace ID does not invent hierarchy.
15. **An icon that carries unrepeated meaning always explains itself.** When adjacent
    text names a person/resource but the icon alone encodes source, mode, risk, or an
    action, wrap that icon in the shared hover/focus tooltip with an accessible name.
    Described tooltips use stable unique ids; icon-only tooltips inside responsive
    slots that duplicate markup use the component's idless `aria_label` mode. A parent
    `title`, color, or visual convention is not a substitute; a decorative icon beside
    text that already says the same thing stays decorative.
16. **Relationship eyebrows lead with the variable entity kind.** In an Actor-to-Target
    detail, position and the arrow already establish the fixed structural roles; `user`,
    `API key`, `runner`, or `policy` is the information that changes. Render
    `USER · ACTOR` / `RUNNER · TARGET`, with the kind first and brighter and the role
    second and quieter. When no kind was recorded, retain the role alone so the empty
    state still has context.
17. **A leading status marker centers on the primary line it qualifies.** When a row
    stacks a primary label over secondary metadata, calculate the marker's top offset
    from the primary line box: `(line height - marker size) / 2`. Do not center it on
    the full content stack or use an unrelated generic margin; both visually detach it
    from the label. Sweep status dots beside stacked copy in `items-start` rows.
18. **Transient recovery is neutral, not an error.** An automatic reconnect, retry, or
    resume that normally resolves without operator action uses neutral styling and
    recovery language. Rose, error icons, and failure copy are reserved for terminal or
    actionable failures. Sweep state-driven notices whose only action is waiting.
19. **Recovery feedback covers the common interruption, not only long outages.** Keep
    a short grace period to suppress zero-duration flicker, but tune it below the normal
    tab-resume reconnect window so the operator can see that recovery occurred. Verify
    brief and sustained disconnects in the browser; a notice whose debounce outlasts
    the common case is functionally absent.
20. **Operational alerts use the icon-capped brand spine everywhere.** The toned icon
    starts a quiet vertical line that binds title, explanation, remedy, and actions into
    one unit. Do not replace it with a tinted wash, ringed box, dashed placeholder, or a
    bare icon-and-copy row. `<.callout>` defaults to this spine and `<.event_block>` adds
    an explicit body/payload contract; `variant={:strip}` is reserved for a shell-wide
    interruption that must span the whole viewport. Sweep: amber/rose `bg-*-500/10`
    alert boxes, dashed pending boxes, and status-result rows that duplicate the spine.
21. **A spine without a visible, semantically exact icon is broken.** Every attention
    block starts with a real `hero-*` glyph; `<.event_block>` rejects empty/invalid names
    and `<.callout>` provides a tone default. Match the metaphor to the prescribed
    action: installing a newer version uses download semantics; `arrow-path` means
    refresh, retry, or work in progress. When introducing a new Heroicon class, verify
    the built asset or its browser-computed mask — a present `<span>` with
    `mask-image: none` is not an icon. Sweep: spine roots without a Heroicon child,
    action/icon mismatches, and computed empty masks.
22. **Spacing utilities only work between element siblings.** When prose and a command,
    secret, or action need a deliberate gap, wrap the prose in `<p>` (or another semantic
    element) before applying `space-y-*`. Raw HEEx text nodes do not match Tailwind's
    sibling selector, so a spacing class can exist while producing no visual space.
    Sweep: `space-y-*` containers with unwrapped text or slot output beside an artifact.
23. **Third-party setup instructions mirror the form the operator actually sees.** Show
    every required literal value as a separately labeled, copyable field; name optional
    credential fields and say explicitly when they stay empty. Keep post-connect tuning
    in a separate optional step with the exact settings path and control names. Never
    collapse a name-plus-URL form into "paste one URL" or make the operator infer which
    product field receives a value. Sweep: setup copy that says "URL only" or combines
    multiple third-party fields behind one copy action.
24. **Shared work queues describe the work, not an assumed viewer.** Approval, review,
    and decision queues use role-neutral state copy unless an item is exclusively
    assigned to one named person. Say "awaiting review" or "pending decision", not
    "waiting on you", when any authorized reviewer can act. Sweep: viewer-relative
    queue headings and counts derived only from broad role permission.
25. **Tooltips open inward from the nearest canvas edge.** A trigger near the left edge
    left-aligns its bubble so it grows right; a trigger near the right edge right-aligns
    it so it grows left. Raising z-index cannot escape an ancestor's overflow boundary.
    Sweep: edge-adjacent tooltips whose bubble points into clipped shell chrome.
26. **A status marker carries status color; adjacent facts remain readable facts.** Keep
    inline counts and ratios neutral when an adjacent dot or chip already signals
    caution. Color a number only when the value itself crosses a meaningful threshold.
    Sweep: conditional amber or rose number classes beside an existing status marker.
27. **Actions for a railed editor stay on the editor track.** When a section reserves a
    right rail for preview or supporting context, its empty-state composer and add row
    occupy the same primary grid columns as saved editors. They do not stretch through
    the rail merely because the rail is empty. Sweep: full-width add rows below 3+1
    editor-and-rail grids.
28. **One-line copy values are compact controls, not code panels.** URLs, tokens, and
    one-line commands use one short row without an internal scrollbar. Clip a long
    preview and copy the complete literal; only genuinely multiline inspectable content
    earns the taller framed panel. Sweep: one-line copy surfaces with forced button
    height, generous block padding, scrollbars, or a separate panel header.
29. **A settings card's state belongs in its title row.** Put `On`, `Off`, `Required`,
    or an equivalent binary-state chip beside the title or at the right edge. Do not
    render a separate status row between the description and the action. Sweep:
    settings cards whose only post-description row is a state chip.
30. **Copy actions do not repeat an obvious artifact noun.** A button inside a command
    surface says `Copy`, not `Copy command`. Qualify the label only when adjacent copy
    targets need distinction, such as `Copy name` and `Copy URL` in a third-party form.
    Sweep: `Copy command` labels inside already-labeled command rows or panels.
31. **Passive binary state in a settings title stays quiet.** When the adjacent action
    already communicates enabled/disabled behavior, render `On` or `Off` as muted
    title-row text rather than a saturated success chip. Reserve colored chips for
    state that needs scanning or attention. Sweep: green binary-state chips above an
    immediately adjacent toggle action.
32. **An unlabeled dot represents only one unambiguous status.** Do not put an
    enabled/disabled dot beside metadata that reports a different status such as sync
    freshness. Leave the healthy default unmarked and name an exceptional state like
    `Disabled` in text. Sweep: entity rows where a dot and adjacent status text describe
    different dimensions.
33. **Setup reassurance is short and operational.** Explain why a potentially
    concerning setting is safe in one plain sentence, then say exactly where to change
    it in one plain sentence. Do not repeat the security model, define product terms,
    or add policy advice inside a mechanical setup step. Sweep: optional setup
    disclosures with multiple paragraphs or more than two prose sentences before the
    control.
34. **Transport diagnostics never render as customer copy.** Hide routine close
    reasons and map abnormal socket or process values to one stable sentence in the
    operator's vocabulary. Keep tuples, atoms, and inspected exceptions in logs or
    audit detail. Sweep: rendered `inspect` output, tuple syntax, and raw disconnect or
    error fields.
35. **Composite metadata values are never clipped by scalar truncation.** A value that
    includes a badge, copy affordance, or other sibling control opts out of a metadata
    field's single-text truncation and wraps as a complete unit. Sweep: `truncate`
    parents around chips, tooltips, or buttons.
36. **A result summary stays with the collection it quantifies.** Search/filter feedback
    such as `1 matching action` or `12 results` renders immediately before or beside the
    result rows. It never joins durable record facts such as `first seen`, hash, owner, or
    timestamps in one middot-separated metadata sentence. Sweep: result counts and
    no-match/search summaries inside meta strips, detail fact lines, or other entity
    metadata instead of adjacent to their result collection.
37. **Casing is a style, never a value transform.** An entity identifier — a runner
    name, a runner group, a slug, a pack id — renders exactly as it was authored, in
    the house identity treatment (sans `font-medium`, mono only where that surface's
    peers are mono). Uppercase is reached for as a CSS `uppercase` class at eyebrow
    metrics (`text-[10px]`/`text-[11px] font-semibold tracking-wider`), which is what
    makes small caps legible; at body size and regular weight it reads as a foreign
    typeface, and a `String.upcase/1` in Elixir additionally spells one identifier two
    ways across surfaces that all show the authored form. Upcasing input is a
    different job and stays legal: a case-insensitive secret or entry code normalized
    to its canonical minted spelling (device-flow code, magic-link code). Sweep:
    `String.upcase`/`String.downcase` on a value that reaches a template, and
    `uppercase` on any element above the eyebrow tier.

### 7.1 Create-flow footer + the ONE back affordance (design-review R1)

- **A form's footer groups its buttons** — primary + quiet cancel side by side
  (`simple_form`'s actions row is `flex gap-3`, never `justify-between`): a pair flung
  to opposite edges loses its association and puts Cancel where the primary
  conventionally sits. A single full-width button (auth pages) still spans naturally.
- **ONE back affordance: `<.back_link>` in the shell `:title`, above the page's job.**
  Never a boxed "← Back to X" button in `:actions`, never an in-body ghost arrow link.
  The shell title is the page's JOB ("Invite a member", "Connect a runner"), not the
  parent section's name; a panel below it never re-titles the page with a near-synonym.
38. **Third-party marks inherit the surface's visual system, not a vendor tile.** Keep the
    recognizable silhouette and an accessible adjacent name, but render small decorative
    navigation/index marks with the same accent, optical size, and hover behavior as sibling
    first-party icons. Do not place mixed full-color logos on isolated white tiles inside
    dark Emisar chrome unless logo fidelity is the content itself (for example, a provider-
    console screenshot). Sweep: small provider or integration marks beside first-party icons
    that introduce their own bright tile, color system, or interaction treatment.
39. **Continuous framed grids keep one track system.** When adjacent rows share borders and one
    enclosure, their dividers must align. If the row semantics need different column counts,
    reuse the parent tracks with column spans, use a truly divider-free full-width band, or
    create a separate surface; never stack mismatched tracks or add a short divider that
    implies a new off-track column.
40. **Scrollable form controls own dark scrollbar chrome.** Every shared textarea carries
    `.scrollbar-control`: a transparent track, inset zinc thumb, dark native color scheme,
    and explicit Firefox plus WebKit styling. Never rely on the OS default inside a dark
    control; it becomes a bright seam on Windows and always-visible-scrollbar systems.
    Sweep: direct `<textarea>` elements, textarea component branches without the shared
    class, and light scrollbar tracks or corners inside console forms.
41. **Compact verdict labels in fixed tracks do not wrap, and peer verdicts share one width.**
    Keep the words readable, delay the compact grid until there is room, and reduce
    horizontal padding before shrinking type. When verdict chips occupy one visual column,
    give them the same fixed, non-shrinking width so both edges align despite different
    label lengths. `whitespace-nowrap` is not a fix by itself: verify alignment plus label
    and page overflow at the narrowest grid breakpoint.
42. **Informative content wears a neutral tone; amber/rose is reserved for a warning or a
    decision.** A runner identity, a content hash, an ID, a version, or any metadata an
    operator merely reads is neutral `zinc` — never tint it amber/rose as if it were the
    problem (the packs page's amber runner tags and amber advertised-hash were the
    correction; the surrounding retired/pending context already carries the concern). A
    compound identity (group + name, key + value) renders through the shared `<.identity_tag
    category= value=>` — the category muted on one side, the specific value brighter on the
    other, split by a divider — never a single tinted chip carrying the pair as prose
    (`<.chip>Group: x</.chip>` was the correction, and the tag had been sitting private in
    `packs_live` where nobody could reuse it). A single-value label stays a `<.chip>`.
    **Corollary — one status per fact, at one level:** when each item already shows its own
    status (a per-version trust badge), a rolled-up status on the container (a "pending"
    badge on the pack header) is a redundant, conflicting second label — drop it. Sweep:
    amber/rose on identity/hash/metadata, chips whose text is `"<Category>: <value>"`,
    private per-page copies of a two-half tag, and a container status that duplicates its
    items'.
43. **A label:value detail row earns its place only when the value carries information — render
    it conditionally, never as an empty placeholder.** A `trusted: — (none yet)` row on a
    never-trusted version, a comparison with nothing to compare, a field that's blank in
    this state — these are noise that dilutes the rows that matter. Show the row only when
    populated (`:if={not is_nil(v.hash)}`), and when the state genuinely differs (a first-
    seen version has bytes but no trusted baseline), render the reduced shape that fits it
    (`on the runner: <hash>`, not `trusted: (none yet)` + `advertising: <hash>`). A one-line
    command or copyable value uses the shared `code_line` (with its label + Copy), never a
    hand-rolled `bg + ring` box or a bare mono line — and it sits a type-step BELOW its
    block title, never above. Sweep: `— (none yet)`/`—`/`n/a` placeholder values, and inline
    `rounded bg-* ring-*` command boxes.
44. **A command snippet shows only what the operator must actually type — verify the CLI before
    you write the copy.** Omit a flag that defaults (`--dest` resolves to the runner's
    configured packs dir), drop a step the tool does itself (`emisar pack install` SIGHUP-
    reloads a running daemon — no `sudo systemctl reload`), and pin an integrity hash IN the
    command's `--hash` rather than a separate row the reader must reconcile against it. Read
    the runner's actual flags/behavior (`runner/pack.go`, `runner/reload.go`) — a snippet is
    instructions someone will paste on a prod host, so a stale flag or a phantom step is a
    real defect. Sweep: install/CLI snippets carrying default-valued flags, manual steps the
    tool automates, or a hash shown twice (in the command and beside it).
45. **Onboarding completion is capability-based, not connection-based.** A connected integration
    counts as usable only when it exposes the capability the next step depends on. When a
    runner advertises no actions, replace the downstream run prompt with the missing catalog
    installation/configuration step, show the exact discovery command, and link the catalog;
    publishing is an author workflow, not a prerequisite for using a public pack. Never
    direct an operator into an action that cannot succeed. Sweep: onboarding checklists that
    mark a connection done while rendering a next step with no available actions behind it.
46. **Page-level attention has one slot, one surface, and one spine grammar per issue.** On list
    pages, render actionable notices together immediately after the intro and before summary
    counters, filters, and data. Operational alerts use the shared icon-capped vertical
    spine, never a tinted or dashed box; the shell-wide `:strip` is the one banner
    exception. **Row-level operational alerts obey the same grammar** — a version's
    retired/pending notice, a row's blocked state — render through `<.event_block>`, never a
    hand-tinted wash box under the row (the packs page's rose/amber boxes were the
    correction). A notice that prescribes a command or other next-step artifact owns that
    payload inside the same spine, never in a sibling box. Multiple notices keep 24px
    between them, while the attention stack leaves a larger 40px exit gutter after whichever
    notice renders last; do not put the same margin on every notice and accidentally make
    inter-alert and post-alert rhythm identical. The same remedy uses the same tone across
    pages; reserve a stronger tone for a different operational consequence, not merely a
    stricter version label. Sweep: boxed/dashed amber or rose alert markup, alert copy
    separated from its code or action, and page-level notice groups without distinct
    internal and exit spacing.
47. **Per-row admin verbs: 1-2 = small bordered buttons; 3+ = the Actions menu. Visible buttons
    always wear a bordered face.** One or two rare verbs render as `size={:sm}` bordered
    `:secondary` buttons opening per-row plain `<.confirm_dialog>`s (the LLM-agents/packs
    grammar) — a dropdown hiding one item is ceremony, and repeated `Actions ▾` triggers
    carry no information. Three-plus verbs earn the team-style labeled menu (`Actions ▾`,
    bordered trigger — never an icon-only `⋯`, which matches nothing else). Either way a
    VISIBLE action button wears a bordered face (`:primary`/`:secondary`) — the borderless
    `:ghost` face is for menu rows and inline cancel/dismiss affordances only; "buttons need
    to look like buttons." Sweep: `variant={:ghost}` action buttons repeated per row in a
    list, icon-only dropdown triggers, and single-item dropdowns.
48. **`whitespace-pre-wrap` content glues to its tags via a one-line inner span.** Template
    indentation inside a pre-wrap element renders as REAL leading whitespace (a stray blank
    + indent before the value). Never put `whitespace-pre-wrap` on a multiline-formatted
    element wrapping an interpolation; keep the established idiom — outer element carries
    the type/color classes, value rides a glued `<span class="whitespace-pre-
    wrap">{@value}</span>` (run_detail's reason_text/error_message rows). Sweep:
    `whitespace-pre-wrap` on an element whose interpolated child sits on its own indented
    line.
49. **Every attention spine starts with a visible, semantically exact icon.** `<.event_block>`
    requires a valid `hero-*` name and `<.callout>` supplies a tone default when no override
    is given; never render a bare vertical line or accept an empty icon. Match the glyph to
    the operator action: version installation uses download semantics, while `arrow-path` is
    reserved for refresh, retry, or work in progress. A new icon is not verified merely
    because its span exists — run the asset build or inspect its computed mask in the
    browser so a missing generated Heroicon class cannot ship as an invisible glyph. Sweep:
    spine roots without a `hero-*` child, icons whose metaphor disagrees with the prescribed
    action, and icon spans whose computed `mask-image` is `none`.
50. **A note that instructs the operator wears the callout spine; the naked `status_note` is
    only for a passive posture fact.** Setup guidance, do-this/leave-that copy, and anything
    the operator acts on inside a flow is an actionable interruption — render it through
    `<.callout>` (tone-default icon capping the event_block spine), never the spine-less
    `<.status_note>`, which is reserved for a passive fact ABOUT the surface (a runner's
    signing posture, a reach statement). Sweep: `<.status_note` whose title or body reads as
    an imperative, or that sits inside a steps/setup flow.
51. **"Managed by <provider>" is stated once at the row, never repeated per attribute.** When a
    row already carries a provisioning badge (the sync badge saying the member is
    directory/IdP-provisioned) plus a lock on each *inline-editable* control the directory
    owns (the role dropdown becomes a locked `hero-lock-closed` chip + a tooltip pointing to
    the provider), do NOT also print a passive `· managed by identity provider` FYI beside a
    *read-only* value — the roster runner-access line was the correction. A read-only value
    has no inline control to lock, so the note only re-says the badge; reserve the "change
    it in your identity provider" wording for the actionable edit-rejection flash, and the
    lock for the control it replaces. Sweep: per-attribute `managed by <provider>` / `synced
    from` prose on a row that already shows a provisioning badge.


## 8. The kit is the contract

- The shared kit lives in `core_components.ex` (+ `EmisarWeb.LiveTable`,
  `EmisarWeb.RunnerScope`). New extractions land as focused commits, each
  migrating all call sites.
- **The design gate:** a console-touching task is done only after a desktop + mobile
  screenshot of the changed surface is reviewed against this doctrine and the design
  system (rebuild the :4010 stack first — a release image needs `docker compose build
  portal`, not restart).
- When a rule here is corrected or extended by the user, update THIS file in the same
  change (taste pipeline) — this doctrine is append-don't-rewrite, like the AGENTS.md
  house opinions.
