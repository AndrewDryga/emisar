# Rule: one shared `core_components` surface per UI shape — never hand-roll it

**Rule.** Every recurring visual shape has exactly ONE component in
`EmisarWeb.CoreComponents`. Reach for it before writing markup; never re-hand-roll
its Tailwind. The canonical surfaces:

| Shape | Component | Never hand-roll |
|---|---|---|
| Bordered section card | `<.card>` (bare) / `<.panel title=>` (card + title header; `variant={:split}` for the bordered `px-5 py-3` header over an unpadded `divide-y` body; `title_variant={:eyebrow}` for the uppercase content label; `:badge`/`:annotation` slots) | `rounded-xl border border-zinc-900 bg-zinc-950/40`, and any `<header>` hand-built inside a `<.card>` |
| Bare section heading | `<.section_header title= count=>` (+`:subtitle`, right-aligned `:actions`) above an unbordered list | a raw `<h2 class="font-display…">` row |
| Inline label / status tag | `<.chip>` (`tone={:neutral\|:brand\|:amber\|:rose}`, `mono`, `upcase` for the uppercase status look) | a bespoke `rounded px-1.5 py-0.5 text-[10px]` span (and there is no `<.tag>` — it merged into `<.chip upcase>`) |
| Tinted callout / banner | `<.callout tone= title= icon=>` (`variant={:strip}` for flush in-card/shell rows; `navigate` makes the whole box a link) — `offline_notice`/`subscription_banner` are its only wrappers, and they map domain state to tone/copy only | a hand-rolled `flex … rounded-lg … bg-amber-500/10 ring-1` box (and `notice`/`error_banner`/`attention_banner` are DELETED — they were this shape) |
| Status dot | `<.status_dot tone= size= pulse ping>` — composed by `status_badge`, `summary_stat`, connection/health/outcome dots | a raw `h-1.5 w-1.5 rounded-full bg-*-400` span or a bespoke animate-ping pair |
| Framed code / snippet | `<.code_panel label= code= annotation= copy prompt max_h=>` — code rides the ATTR so the formatter can't leak whitespace into the `<pre>` (run-output's streaming terminal is the one sanctioned hand-roll) | a `border … bg-black/… <pre>` block with a copy-button header |
| Collapsible details | `<.disclosure size={:sm\|:md}>` (`open` server-owned when state must survive re-renders) | a raw `<details>`/`<summary>` with a chevron |
| Empty / zero state | `<.empty_state icon= title=>` (`:boxed` default, `:bare` for in-card, `tone={:danger}` for load-failure) | a dashed `border-dashed` box with icon + `<p>`s |
| Page width + rhythm | `<.dashboard_shell width={:table\|:detail\|:form\|:settings}>` owns it | `mx-auto max-w-*` / `<.page_container>` (deleted) |
| Index lead line | `<.page_intro>` (under the shell `:title`) | a hand-rolled `<header>` + `<p>` intro |
| Detail breadcrumb + heading | `<.detail_header back= navigate=>` in the `:title` slot | a bespoke back-link + `<h1>` |
| Auth footer switch-line | `<.auth_footer_link navigate=\|href=>` (`:lead` slot) | a per-page `<p class="mt-… text-center">` + link |
| Initial-letter identity disc | `<.avatar name= size={:xs\|:sm\|:md} shape={:circle\|:square}>` — `:circle` for people (shell user, team roster), `:square` for workspaces (account switcher) | a `grid … place-items-center rounded-full bg-zinc-800 … uppercase` span + `String.first` |
| Radio choice-card group | `<.choice_cards name= value= columns=>` + `:card value= icon= title=` slots — sr-only radio, NEUTRAL selection ring + check (a chosen risky option never wears the safe hue) | a hand-rolled `<label>` + radio card list, or per-page selected-class helpers |
| Reveal-once credential | `<.secret_reveal secret=\|codes= variant={:banner\|:card} download_name= on_dismiss=>` (`:install_command`, `:actions` for "I've saved them"; per-code cells + Copy all ride `data-copy-text`) | an amber `bg-amber-500/10 ring-amber-500/30` box with its own copy wiring, or a hidden blob element for Copy all |
| TOTP enrollment block | `<.mfa_enrollment qr_svg= uri= form= variant={:stacked\|:split}>` (`:instructions`, `:actions`; owns the QR wrapper + can't-scan disclosure + the `code_input` confirm form) | a hand-rolled white QR box + URI disclosure, or a plain text input for the OTP |

**The stat trio** — three count/number components that look alike and get confused.
Pick by *where it lives*:

- **`<.stat label= value= hint=>`** — a dashboard **KPI tile**: a big `text-3xl`
  number in its own `<.card>`. For the dashboard's top metrics grid only.
- **`<.summary_band>` + `<.summary_stat tone= value= label=>`** — the quiet
  horizontal **count strip at the top of a LIST page** (runners fleet online/offline,
  the agents page). A dot + count + label per stat, one bordered flex row.
- **`<.meta_strip cols=>` + `<.meta_field label=>`** — the bordered horizontal
  **key-value strip under a DETAIL page title** (a run's runner / risk / pack / time).
  Uppercase label over value, not a count.

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

<.panel variant={:split} title="Recent runs">
  <:actions><.link navigate={~p"/…/runs"}>View all</.link></:actions>
  <ul class="divide-y divide-zinc-900">…</ul>
</.panel>

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
confirm ladder, density budgets — is `.agent/rules/console-ux.md`; this file is the
shape→component map it leans on.
