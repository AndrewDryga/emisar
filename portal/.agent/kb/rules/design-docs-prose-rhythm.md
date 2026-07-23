# Rule: docs prose pages share one vertical rhythm through `docs_components`

**Rule.** A `/docs/*` prose page never sets its own body typography. It renders
through the shared shell (`docs_layout`, `docs_header`, `docs_h2`/`docs_h3`,
`docs_code`, `docs_callout`) and inherits one rhythm:

- **Body copy is `text-base` (16px).** No `text-sm`/`text-xs` paragraphs, no
  per-client or per-section size drift. 14px body on a wide column reads dense —
  the eye crosses 100+ characters, then drops to a distant next line.
- **The reading measure is capped.** `docs_layout` caps the content column at
  `max-w-2xl` (~72–84ch at 16px). Code, tables, and figures all fit inside it,
  so one cap keeps every block on the same left edge — don't widen the column
  or hand a page its own wider wrapper.
- **One line-height.** `docs_layout` pins `[&_p]:leading-7 [&_li]:leading-7` on
  the content column, so every paragraph and list item lands on the same
  leading whether or not the call site set it. On 16px body, `leading-7` is the
  correct 1.75 ratio; don't fight it with an inline `leading-6`/`leading-8`.
- **One block gap.** Paragraphs and `docs_code` sit at `mt-5`; callouts at
  `mt-6`; `docs_h2` at `mt-12`, `docs_h3` at `mt-8`. A list that continues a
  colon-intro paragraph may couple tighter (`mt-4`), but its items breathe at
  **`space-y-3`** — never `space-y-1.5`/`space-y-2`/`space-y-2.5`.

**Intentional exceptions — these stay `text-sm`/compact:** table cells and
inline `font-mono` snippets (reference density is denser by design); the
`docs_mcp_reference` `[&_ul]` article (short single-line API items at
`space-y-1.5`); and `docs.html.heex`, the card-grid `/docs` index, which is not
a prose page and owns its own layout.

**Why.** The docs read dense not because the leading was tight — it measured a
loose 2.0 — but because 14px copy ran full-column-wide. One size (16px) on one
capped measure is the premium-docs formula (Stripe, Tailwind, Linear all cap the
measure), and it reads calm on the first pass. Pinning leading at the shell
means a new page can't silently reintroduce the drift.

**✅ Good**

```heex
<.docs_h2 id="roles">Roles</.docs_h2>
<p class="mt-5 text-base leading-7 text-zinc-400">Four ordered roles…</p>
<ul class="mt-4 space-y-3 text-base leading-7 text-zinc-400">
  <li>…</li>
</ul>
<.docs_code label="shell">…</.docs_code>
```

**❌ Bad**

```heex
<%!-- 14px body, ad-hoc leading, packed list, no measure cap on the page --%>
<p class="mt-3 text-sm leading-relaxed text-zinc-400">Add to your config:</p>
<ul class="mt-2 space-y-2 pl-5 text-sm text-zinc-400">
  <li>…</li>
</ul>
```

**Sweep** (docs prose pages — `docs_*.html.heex` + `connect_llm.html.heex`,
excluding the `docs.html.heex` index and the `docs_mcp_reference` article):

- `grep -nE 'text-sm[^"]*text-zinc-(400|300)'` (minus `font-mono`) — body copy
  stuck at 14px.
- `grep -nE '<[uo]l class="[^"]*space-y-(1\.5|2|2\.5)[^"]*text-(base|sm|zinc)'` —
  prose list containers tighter than `space-y-3`.
- body `<p>`/`<li>` carrying an inline `leading-6`/`leading-8` — the shell
  already supplies `leading-7`.
- a docs page (or its wrapper) that sets its own `max-w-*` wider than the shell.

**Enforced.** The `docs_layout` `max-w-2xl` cap and `[&_p]:leading-7
[&_li]:leading-7` contract pin measure and leading structurally — a page can't
render body text on a different line-height or a wider column without editing
the shell. Body size, block gaps, and list spacing are this rule plus the grep
sweep above; the `marketing`/`marketing_structural` tests render every page.
