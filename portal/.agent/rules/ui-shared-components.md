# Rule: one shared `core_components` surface per UI shape — never hand-roll it

**Rule.** Every recurring visual shape has exactly ONE component in
`EmisarWeb.CoreComponents`. Reach for it before writing markup; never re-hand-roll
its Tailwind. The canonical surfaces:

| Shape | Component | Never hand-roll |
|---|---|---|
| Bordered section card | `<.card>` (bare) / `<.panel title=>` (card + title header) | `rounded-xl border border-zinc-900 bg-zinc-950/40` |
| Inline label / status tag | `<.chip>` (`tone`, `mono`, `upcase` for the uppercase status look) | a bespoke `rounded px-1.5 py-0.5 text-[10px]` span (and there is no `<.tag>` — it merged into `<.chip upcase>`) |
| Alert banner | `<.error_banner>` (rose, form/structural errors) · `<.notice variant={:info\|:success\|:warning}>` (everything else) | a hand-rolled `flex … rounded-lg … bg-amber-500/10 ring-1` box |
| Empty / zero state | `<.empty_state icon= title=>` (`:boxed` default, `:bare` for in-card, `tone={:danger}` for load-failure) | a dashed `border-dashed` box with icon + `<p>`s |
| Page width + rhythm | `<.dashboard_shell width={:table\|:detail\|:form\|:settings}>` owns it | `mx-auto max-w-*` / `<.page_container>` (deleted) |
| Index lead line | `<.page_intro>` (under the shell `:title`) | a hand-rolled `<header>` + `<p>` intro |
| Detail breadcrumb + heading | `<.detail_header back= navigate=>` in the `:title` slot | a bespoke back-link + `<h1>` |

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
<.card class="overflow-hidden" padding="">
  <header class="border-b border-zinc-900 px-4 py-2">…</header>
  <pre>…</pre>
</.card>

<.chip upcase tone={:emerald}>Trusted</.chip>
<.notice variant={:warning}>Copy the token now — we won't show it again.</.notice>
```

**❌ Bad**

```heex
<div class="overflow-hidden rounded-xl border border-zinc-900 bg-zinc-950/40">…</div>
<span class="rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase …">Trusted</span>
<div class="flex … rounded-lg bg-amber-500/10 p-3 ring-1 ring-amber-500/30">…</div>
```

**How it's enforced.** Review + grep, not Credo (a class-string heuristic can't tell a
deliberate one-off from a drift). Before adding markup, grep `core_components.ex` for
the shape; if you find yourself typing `rounded-xl border border-zinc-900
bg-zinc-950/40`, `bg-amber-500/10 … ring-1`, or `mx-auto max-w-`, stop — there's a
component. The sole sanctioned hand-roll is the packs pack-row: a stream `<li>`
wrapping a nested version list, which can't be a `<div>` `<.card>` and isn't a flat
`<.list_row>` (noted at the call site).
