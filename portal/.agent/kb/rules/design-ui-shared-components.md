# Rule: one shared `core_components` surface per UI shape — never hand-roll it

**Rule.** Every recurring visual shape has exactly ONE component in
`EmisarWeb.CoreComponents`. Reach for it before writing markup; never re-hand-roll
its Tailwind. The canonical surfaces:

| Shape | Component | Never hand-roll |
|---|---|---|
| Canvas section | `<section>` + `<.section_header title=>` (subtitle/actions/count slots) — `.card`/`.panel` are DELETED (§8.1: boxes only for secrets, code, and forms; alerts use the spine; `Emisar.Checks.NoIslandContainers` enforces) | resurrecting a wash card/panel around content, or a hand-built `<header>` over a section |
| Bare section heading | `<.section_header title= count=>` (+`:subtitle`, right-aligned `:actions`) above an unbordered list; `actions_align={:baseline}` for a plain inline text link beside the title; subtitles use the available section width and wrap naturally | a raw `<h2 class="font-display…">` row, page-specific alignment overrides, or an arbitrary subtitle max-width that leaves usable space empty |
| Consequential-action row | `<.confirm_zone tone={:neutral\|:danger\|:success}>` — shared title/body tiers, row padding, and icon-free medium button; `:heading` can render a live fact and `show_action={false}` preserves the read-only row | moving a peer action into the section header, enlarging its help text, or giving it a different button size/icon |
| Exact timestamp tooltip | `<.local_time styled_tooltip>` — compact local date/time line, muted timezone/instant-specific offset, and inline full-precision UTC reference; tooltip-sized type and padding through the shared `:content` slot | oversized clock typography, card-like sections/dividers, a concatenated wrapping sentence, or a separate tooltip mechanism |
| Button (filled or bordered) | `<.button>` — `variant={:primary\|:secondary\|:ghost}` × `tone`, `size={:lg\|:md\|:sm}`, optional leading `icon`; pass `navigate`/`patch`/`href` and it renders a styled `<.link>` with the identical face. **An accent fill is a LIGHT surface, so its label is near-black** — `bg-brand-500 text-zinc-950`, amber's twin `text-amber-950`. Full-width in a narrow card is `class="w-full"`, nothing else | a hand-rolled `rounded-lg bg-brand-500 px-4 py-2.5 … text-white` face (white on emerald-500 is ~1.9:1 and unreadable), a bespoke `border border-zinc-700 … text-zinc-300` secondary, or a `<.link>` dressed up with button classes |
| Inline label / status tag | `<.chip>` (`tone={:neutral\|:brand\|:amber\|:rose}`, `mono`, `upcase` for the uppercase status look) | a bespoke `rounded px-1.5 py-0.5 text-[10px]` span (and there is no `<.tag>` — it merged into `<.chip upcase>`) |
| Attention callout / banner strip | `<.callout tone= title= icon=>` defaults to the icon-capped vertical spine and always resolves a real `hero-*` icon; `navigate` makes the whole unit a link. `variant={:strip}` is reserved for a flush shell-wide interruption. `offline_notice`/`subscription_banner` only map domain state to tone/copy. A command or prescribed action belongs inside this callout, so warning + remedy remain one surface. | a hand-rolled `flex … rounded-lg … bg-amber-500/10 ring-1` or dashed alert box, a bare line with no visible icon, a callout followed by a sibling code artifact, or using the shell strip for an ordinary in-page alert |
| Naked status note (canvas) | `<.status_note icon= tone= title= primary>` — toned icon lead + title + body, NO spine, for a passive fact ABOUT the surface (posture fact, reach statement); `primary` = the page's strongest status voice (semibold). | a hand-rolled `flex items-start gap-3` + `mt-0.5 h-4 w-4` icon + title/body divs, or using a status note for an operational alert that needs the shared spine |
| Event block | `<.event_block icon= tone={:amber\|:rose\|:brand\|:neutral} title=>` + `:body` slot + payload in the default slot — the explicit alert form when title, explanation, artifact, and actions must stay one unit. Its required `hero-*` icon caps the same spine as `<.callout>`. `:amber` = pending/attention; `:rose` = a dead outcome; `:brand` = a positive result carrying real content. | a `border-l-2` wrapper, a boxed or dashed alert, an empty/invisible icon, or three floating elements for one result |
| Status dot | `<.status_dot tone= size= pulse ping>` — composed by `status_badge`, `summary_stat`, connection/health/outcome dots | a raw `h-1.5 w-1.5 rounded-full bg-*-400` span or a bespoke animate-ping pair |
| Setup connection status | `<.connection_status id= state={:waiting\|:delayed\|:connected} title=>` — shared runner/agent setup row; neutral waiting pulse, amber delayed pulse with optional `:details`, static green when connected; one polite live region | separate waiting layouts per installer, amber for normal waiting, duplicate timeout alerts, or a decorative progress card |
| Framed code / snippet | `<.code_panel label= code= annotation= copy prompt max_h=>` — code rides the ATTR so the formatter can't leak whitespace into the `<pre>` (run-output's streaming terminal is the one sanctioned hand-roll) | a `border … bg-black/… <pre>` block with a copy-button header |
| User-authored artifact | `<.artifact_panel>` — a quiet framed surface for operational Markdown or another authored artifact that must remain distinct from surrounding controls | naked authored instructions that blend into page copy, or a one-off wash/ring wrapper |
| Searchable finite catalog | `<.searchable_select id= name= value= selected_label= groups=>` — concise closed identity, grouped searchable metadata in the panel, disabled values skipped by keyboard selection | long native selects, metadata-concatenated triggers, or a local combobox implementation |
| Collapsible details | `<.disclosure size={:sm\|:md}>` (`open` server-owned when state must survive re-renders) | a raw `<details>`/`<summary>` with a chevron |
| Empty / zero state | `<.empty_state icon= title=>` (`:boxed` default, `:bare` for in-card, `tone={:danger}` for load-failure) | a dashed `border-dashed` box with icon + `<p>`s |
| Page width + rhythm | `<.console_shell width={:table\|:detail\|:form\|:settings}>` owns it | `mx-auto max-w-*` / `<.page_container>` (deleted) |
| Index lead line | `<.page_intro>` (under the shell `:title`) | a hand-rolled `<header>` + `<p>` intro |
| Detail breadcrumb + heading | `<.detail_header back= navigate=>` in the `:title` slot | a bespoke back-link + `<h1>` |
| Auth footer switch-line | `<.auth_footer_link navigate=\|href=>` (`:lead` slot) | a per-page `<p class="mt-… text-center">` + link |
| Initial-letter identity disc | `<.avatar name= size={:xs\|:sm\|:md} shape={:circle\|:square}>` — `:circle` for people (shell user, team roster), `:square` for workspaces (account switcher) | a `grid … place-items-center rounded-full bg-zinc-800 … uppercase` span + `String.first` |
| Radio choice-card group | `<.choice_cards name= value= columns=>` + `:card value= icon= title=` slots — sr-only radio, neutral selected surface + check, and a persistent brand ring that marks the active input before focus. **Any pick-one comparison grid whose options carry their own CTAs (billing plan cards) reuses the RECIPE even when it can't be a radio group:** `rounded-lg p-*`, current/selected = `bg-white/[0.06] ring-2 ring-brand-500/50`, rest = `bg-black/20 ring-1 ring-zinc-800` — never a green fill, status treatment, or bespoke card wash | a hand-rolled `<label>` + radio card list, per-page selected-class helpers, or a `border-zinc-800/70 bg-zinc-950/40` comparison card |
| Recovery-code reveal | `<.secret_reveal codes= download_name=>` (`:actions` for the shared saved-codes acknowledgement; shared copy controls and a neutral dashed code grid) | a colored credential panel, bespoke copy/download buttons, or a second saved-codes confirmation |
| TOTP enrollment block | `<.mfa_enrollment qr_svg= setup_key= form= variant={:stacked\|:split}>` (`:instructions`, `:actions`; owns the QR wrapper, manual-key disclosure and code input; wraps by available width) | a hand-rolled QR box, raw provisioning URI, or plain text input for a six-digit OTP |
| Console section with help | `<.section_with_note id=>` (`:header`, content, optional `:note`) | duplicated primary/help grids or fixed offsets to align the note |
| Ordered or parallel steps list | `<.steps variant={:guide\|:plan} marker={:number\|:parallel}>` + `:step` slots (numbers derive from slot order; a parallel plan uses the shared parallel icon; `:plan` = the runbook's divide-y rows) | a hand-numbered `<ol>` with "1." spans, `list-decimal`, middot bullets for ordered checks, bespoke number circles, or per-page parallel markers |
| Middot meta row | `<.meta_line mono>` + `:seg` slots — separators render only BETWEEN visible segments | hand-joined `a · b · c` runs with `{" "}` whitespace hacks, or a trailing `{expr} ·` (formatter-looping) |
| One-line code + copy | `<.code_line id= value=>` (single value; multi-line snippets are `code_panel`) | a bespoke `flex … bg-zinc-950/80 ring-zinc-800` row wrapping `<code>` + `copy_button` |

Page-header actions use shared medium buttons (`size={:md}`), matching Runners
and Runbooks. When moving a compact row action into the page header, update its
size to match that destination; do not carry over the row's small-button styling.

Group settings by the operator question they answer. Connection status and its
verification actions belong together; sign-in configuration stays separate from
provisioning and access. Put new-member policy, directory sync and its member list
under User provisioning & directory sync. Groups & access owns one paginated list of every synced group, including
unmapped groups, with member counts and role controls. Do not duplicate those
groups in separate role, access or synced-group tables.
Use Team's in-place role dropdown for live groups: Map role before a mapping,
the current role afterward. Choosing a role saves it for that exact row; do not
open another group picker or require a separate Edit/Save form for one choice.
Keep the header Add mapping form for searching beyond the current page and preserve
its open draft. Show failures beside the group and clear them after a successful
create, change or removal, including changes made through the header form.
Put Remove mapping at the bottom of the role dropdown, separated from role choices
by the shared divider and styled with the rose menu tone. It opens the existing
confirmation, rendered outside the dropdown; do not duplicate it as a row button.
Removing a mapping removes only its grant, never the directory group. Keep retired
groups with saved mappings visible as No longer synced until the mapping is removed;
their role menu offers removal only, with no role choices or empty divider.
Show runner and pack scope chips beneath each group, without an extra Default label.
Unmapped access uses connection defaults; mapped access shows defaults plus the group's
additive grant, not a member's total access across every group. Keep member count,
role dropdown and Edit access together in the primary row's trailing action cluster.
Edit access opens the existing scope selectors attached to that row, without another
group picker. Keep the outer row unframed and its identity/actions at the same inset
and top position in both states; separate the editor with vertical spacing, not an
edit-only border or padding that moves the row. Preserve the shared selectors'
established selected-input styling. The selectors display effective access, with
inherited defaults checked and locked and an explanation on each lock. All, Selected
and No runners/No packs choices remain visible; disable any choice below the defaults.
When the default is All, lock the selected All choice and every alternative. Named
defaults stay checked while the operator adds scopes or selects All.
Do not repeat default role/access summary lines under the group heading;
the default-role chip stays in the contextual role explanation.
Keep the raw additions separate from their effective form presentation. Disabled
inherited controls must not become hidden submitted copies or permanent grants.
Saving exactly the defaults needs no mapping. Runner and pack additions are
independent, so widening one cannot freeze the inherited other dimension. Combine
all mapping dimensions before normalizing member access; zero runner reach still
means no actions. Refresh defaults and their locks without replacing draft additions.
Reset to defaults removes only the access mapping, not the role or directory group.
Preserve drafts through refresh, rejected saves and unrelated removals. Close a
missing or retired row's editor with a visible explanation rather than leaving
invisible editor state that locks every other row. Keep retired rows until both
saved mapping types are removed, and expose removal only for them. Hide the group
section when directory mapping is unavailable rather than leaving an empty heading.
Do not isolate defaults in a metadata strip or unrelated settings table.

Directory relationships must stay usable without loading the entire directory.
Directory groups and their filters belong on the SSO connection page, not Team.
Team shows effective role/access and connection attribution, without group badges,
group choices or group-roster reads. Connection members show at most three group
chips, with searchable paginated overflow when there are more. Keep every read
scoped to the current connection. Label the row IdP groups, distinct from runner
groups. Use a single group-name chip; the connection already identifies its
provider. Clicking a badge toggles that member table's group filter; active badges use the
shared brand tone. Every supported filter must have its normal shared dropdown,
even when badges or links can apply it. Choices show only group names on this single-provider page, including the
selected choice retained outside a searched page. Do not repeat the provider in
each option's description. No one-off selected-filter banner or
badge-only filtering. Reuse LiveTable's filter form on nested lists too. Large
choice sets use server search and ten-choice pages inside the shared dropdown,
with the current selection retained outside the page. Keep the menu open while
searching, preserve search/page drafts through refresh, and provide first-page
recovery when a cursor becomes empty. Changes clear only that table's cursor and
preserve sibling filters. A missing or unauthorized group remains visibly
unavailable and clearable; never fall back to an unfiltered roster.
Groups & access names stay plain; clicking a member count applies that group's
filter to Members above, clears member search/cursor state, and scrolls/focuses
that section on the same SSO page. Preserve the Groups & access search and page;
never navigate to Team for this drill-down. Do not show directory-member hover previews on names,
badges or counts: use the filterable roster. Group and connection-member lists
have independent server-side searches and cursors. Keep count/filter populations
consistent: include suspended people, exclude removed relationships, and fence
workspace and connection ownership. Batch visible-row summaries; never fetch a
whole directory or preload one full group roster per row. Keep only one paginated
overflow list open; refresh or clear it when relationships disappear. Failed
reads show unavailable, not zero members.

Member origin badges describe how the identity was connected, not current sync
health. Use SCIM for directory-created identities, SSO for first-sign-in creation,
and Linked for self-linked or administrator-approved identities. Explain each
origin through the shared tooltip; do not call an OIDC-linked identity Synced or
use native title tooltips for the same explanation. Team needs no generic page
introduction; the roster and its read-only state explain the available work.

Use quieter `section_header level={3}` headings for
subsections within a named section. Multi-row settings tables share one label/value
alignment in the primary column; the side rail holds help. Where a section needs one or two
summary facts, use a compact summary rather than another table:
keep labels next to values, emphasize the value, and use the existing role/scope
chips. Related summary items wrap at their natural widths; never reserve an empty
fixed label column or add a card around them.

Peer integration sections use the same heading → status/actions → settings
hierarchy. Keep configuration state distinct from historical evidence: an
authenticated SCIM request is "Last request", not a completed sync or a live
connection. Normal initial waiting is neutral. Setup instructions remain
available after setup; request age alone must not hide, reopen, or reset them.
User provisioning & directory sync combines New members and SCIM as content-sized
columns in the Sign-in status row pattern. Put each label above its value. SCIM
reads `Enabled (last request ...)`: only Enabled is colored; the parenthetical
history stays muted and inline, not a third column. Use a muted waiting note
before the first request and Disabled without history when off. No extra status dot.
Keep management controls on the right of that
same row within the primary column. Stack controls below on narrow screens.
Do not repeat a separate Directory sync heading or isolate New members above
the status row. Preserve the new-member policy when SCIM is unavailable.
Do not turn these statuses into a bordered key/value table or put actions beside
the heading. Keep its setup-only Base URL and Copy control inside step 2 of Setup
instructions, directly under the endpoint instruction and aligned with that step's
text. Copyable values belong with the instruction that uses them, not in a loose
row above the guide. Preserve one-time token visibility and the guide's open state
after enable or rotation; a layout change must not alter credential handling.
Explanations of configurable defaults show the actual value using its shared
badge, rather than making the operator look elsewhere to resolve "the default".

A standalone read-only endpoint in settings uses a plain label and shared
`copyable_id` value. Do not stack table dividers and a framed code field around
that one fact; keep the copy affordance beside the value. Its label uses an
intrinsic-width column with a small gap, not a fixed settings-table track;
let label and value wrap when their content needs the space, not at an arbitrary
viewport breakpoint.

An empty table or directory list still needs a compact shared empty state in
its body when its Add action sits in the header. Hide that placeholder when an
inline creation form replaces the empty body; do not duplicate its Add action.
Keep failed reads and stale-page recovery distinct from genuinely empty lists,
and do not render a zero count or an empty pagination spacer for a failed read.

Inline mapping forms use compact aligned controls and a bounded form width,
without repeating the section action as a second heading. A searchable group
choice is a closed field with results in the shared dropdown, not a permanently
expanded directory beside another input. Keep server-side search for unbounded
directories and retain the current choice while searching for a replacement.
Search inputs in a form dropdown do not submit the outer form on Enter. Hidden
metadata inputs carry the `hidden` attribute so spacing utilities ignore them.

Access mapping forms reuse the invitation flow's `choice_cards`, attached
`runner_scope_select`, and `pack_access_field` controls. Do not substitute native
mode selects for the shared runner/group and pack selection pattern. Keep each
flow's allowed modes, defaults, submitted values, and authorization unchanged.
A detail page's danger section fills its primary content column, without an
additional width cap; it does not span the help rail. Preserve the shared
consequential row and its confirmation.

Inline edits replace the value they edit in the same row when the field fits;
do not duplicate a saved badge above a detached full-width editor. Larger access
editors replace the saved scope summary beneath the same group identity. Keep
Save/Cancel with those fields and hide competing Edit/Delete controls while
editing. A self identity marker never replaces the member's role. Read-only
roles use the same shared chip for self and other members, with a shared tooltip
explaining restrictions; do not turn the self role into a disabled button.
Unavailable action controls remain disabled buttons with an explanation.

Mapping uniqueness errors belong to the visible directory-group field, not the
hidden provider identifier. Preserve database constraints and show rejected
submission errors even when the selected resource is serialized by a hidden
input. Keep the chosen group and other form values so the user can correct them.

Shared authentication actions preserve the initiating surface on failure as well
as success. Choose a purpose-specific return page only after validating the
signed request's actor, account and session binding. Never trust a submitted
return URL or unverified purpose/provider fields; invalid requests use a safe
internal fallback.

Setup actions own their empty state: omit a redundant "Not configured" sentence
when an Add control already communicates the next step. Plan-gated setup keeps
the same button disabled, replacing its action icon with `state.locked`. Match
Audit's SIEM-export treatment: a downward shared tooltip saying
"<Feature> requires the Team plan or above." Use the actual required plan and
keep the button size appropriate to its location.
Hide dependent settings until their prerequisite is configured; preserve actual
enforcement state and read failures rather than treating them as an empty setup.
Members without management access retain the shared read-only setting value.

An action that opens a row's inline editor must not reset or do nothing when
that same editor is already open. Toggle it closed without saving, label the
active action as Cancel, and expose its expanded state. Opening another row or
editor keeps one editor open at a time; reopening starts from saved values.

Align a column's heading and values to the same edge. A styled `<.local_time>`
uses an inline-flex tooltip wrapper: text alignment alone does not position its
flex child. Match the cell/container alignment, not just the text utility.

Repeated authoring fields use the shared `input` compact size, as in policy
Action overrides and runbook inputs, arguments, outputs, and success conditions.
Keep adjacent qualifiers and enum-default controls at the same visible height;
their hit areas can extend beyond that face without overlapping nearby controls.
Measure row gaps between visible control faces, accounting for the compact icon
button's inset face. Allocate that inset in the row's spacing rather than relying
on a negative margin on the button to cancel a full field gap. Conditional fields
take width from a flexible expression or value column; peer source/method selects
keep their widths when the field appears.

Runbook output pickers show stdout and stderr, not a separate structured-output
stream. Schema-validated stdout remains a distinct canonical binding chosen from
the trusted common action contract for new or edited JSON Pointer bindings.
Preserve valid saved sources on load, unrelated edits, and sibling removal;
text extractors always read a text stream. Never rewrite historical definitions
or approval identities to simplify a picker label.

Console table icons are monochrome. `LiveTable` owns `emisar-icon-mono` on its
table, card-list, and responsive mobile-row containers; `source_badge` also owns
it because a dispatch source is metadata, not an outcome. Internal icon accents
inherit `currentColor` instead of adding colored details to neutral cells.
Preserve the surrounding tone of status badges, warnings, and consequential
actions; this rule does not make outcomes indistinguishable.

Copyable commands preserve meaningful whitespace in both the rendered code and
clipboard payload. Use `whitespace-pre` for `code_line` previews and the literal
`data-copy-text` path for Copy; neither should discard an intentional leading
space. Do not promise that a leading space prevents shell-history recording:
that depends on the user's shell settings.

A height-clamped code panel scrolls inside its code body even when lines wrap.
Keep its heading and Copy control outside that scroll region, retain the full
clipboard payload, and make the scrollable body keyboard-focusable.

Discarding unpublished edits uses the amber confirmation treatment. With no
unsaved edits or saved unpublished draft, keep the control disabled and neutral;
do not style it as an active destructive action or write a no-op discard.

Human-readable badge labels use sentence case: `Reusable`, `No expiration date`,
`Revoked`, `Used up`. Keep peer badges consistent, including conditional states.
Preserve identifiers, brand names, and acronyms; the explicit `upcase` status
variant remains an intentional exception. Set the copy correctly rather than
applying CSS capitalization to arbitrary badge contents.

**The stat trio** — three count/number components that look alike and get confused.
Pick by *where it lives*:

- **`<.stat label= value= hint=>`** — a dashboard **KPI tile**: a big `text-3xl`
  number in its own `<.card>`. For the dashboard's top metrics grid only.
- **`<.meta_strip cols=>` + `<.meta_field label=>`** — the bordered horizontal
  **key-value strip under a DETAIL page title** (a run's runner / risk / pack / time).
  Uppercase label over value, not a count.

Native select options stay inline inside their shared select component, including
grouped options. Do not make each `<option>` a separate function component:
LiveView can replace an unchanged component with an attribute-less skip placeholder,
and the browser's select parser can choose the prompt instead. The resulting DOM
patch can reset the displayed value without changing its server-side filter or
highlight. Mark an explicitly selected blank prompt as selected too. Exercise a
sibling-filter change from a nonblank default, then an explicit All choice, when
verifying selection, highlighting, and submitted values.

**Why.** A security console's trust comes from looking the same everywhere — a card
that's 1px or one opacity off, a fifth shade of amber banner, a second "tag"
primitive, all read as *something is subtly wrong here*. One component per shape
means one place to fix a spacing bug, one review surface, and zero drift. The audit
that triggered the redesign found 13 full-bleed + 6 hand-rolled widths, ~15 cards in
three border looks, `tag` ≈ `chip`, and an undocumented stat trio — all the cost of
hand-rolling shapes that already had a home.

**✅ Good**

```heex
<.code_panel label="Arguments" annotation={"sha256:" <> sha} max_h="max-h-64" code={json} />

<section>
  <.section_header title="Recent runs">
    <:actions><.link navigate={~p"/…/runs"}>View all</.link></:actions>
  </.section_header>
  <ul class="divide-y divide-zinc-800/70">…</ul>
</section>

<.chip upcase tone={:brand}>Trusted</.chip>
<.callout tone={:amber}>Copy the token now — we won't show it again.</.callout>
```

**❌ Bad**

```heex
<div class="overflow-hidden rounded-xl border border-zinc-900 bg-zinc-950/40">…</div>
<.card padding=""><header class="border-b border-zinc-900 px-4 py-2">…</header>…</.card>
<span class="rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase …">Trusted</span>
<div class="flex … rounded-lg bg-amber-500/10 p-3 ring-1 ring-amber-500/30">…</div>
```

**How it's enforced.** Review + grep, not Credo (a class-string heuristic can't tell a
deliberate one-off from a drift). Before adding markup, grep `core_components.ex` for
the shape; if you find yourself typing `rounded-xl border border-zinc-900
bg-zinc-950/40`, `bg-amber-500/10 … ring-1`, or `mx-auto max-w-`, stop — there's a
component. Two sanctioned hand-rolls, both noted at their call sites: the packs
pack-row (a stream `<li>` wrapping a nested version list — can't be a `<div>`
`<.card>`, isn't a flat `<.list_row>`) and the run-detail output terminal (streams
chunk spans into its `<pre>`, which `<.code_panel>`'s static `code` attr can't).

The page-level layer on top of this rule — archetypes, the ONE tone vocabulary, the
confirm ladder, density budgets — is `.agent/kb/rules/design-console-ux.md`; this file is the
shape→component map it leans on.
