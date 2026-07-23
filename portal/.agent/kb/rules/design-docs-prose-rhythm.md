# Rule: docs prose pages share one vertical rhythm through `docs_components`

**Rule.** A `/docs/*` prose page never sets its own body typography. It renders
through the shared shell (`docs_layout`, `docs_header`, `docs_h2`/`docs_h3`,
`docs_code`, `docs_callout`) and inherits one rhythm:

- **Body copy is `text-sm`.** No `text-base`/`text-xs` paragraphs, no
  per-client or per-section size drift.
- **One line-height.** `docs_layout` pins `[&_p]:leading-7 [&_li]:leading-7`
  on the content column, so every paragraph and list item lands on the same
  leading whether or not the call site remembered a `leading-*` class. Don't
  fight it with an inline `leading-6`/`leading-8` on body text.
- **One block gap.** Paragraphs and `docs_code` sit at `mt-5`; callouts at
  `mt-6`; `docs_h2` at `mt-12`, `docs_h3` at `mt-8`. A list that continues a
  colon-intro paragraph may couple tighter (`mt-4`), but its items breathe at
  **`space-y-3`** — never `space-y-1.5`/`space-y-2`/`space-y-2.5`.

**The one exception is a reference list of short, single-line items** — the
`docs_mcp_reference` `[&_ul]` article, an API/param enumeration — where compact
`space-y-1.5` is correct scannable density, not drift. Prose (multi-line,
explanatory) list items always breathe.

**Why.** Inconsistent leading and uneven block gaps make a page read *dense*
even when the content is short — the exact complaint that opened this rule
("missing vertical rhythm", then "still no rhythm"). One shared rhythm reads
calm and lets the reader get it on the first pass. Pinning leading at the shell
means a new page can't silently reintroduce the drift.

**✅ Good**

```heex
<.docs_h2 id="roles">Roles</.docs_h2>
<p class="mt-5 text-sm text-zinc-400">Four ordered roles plus one seat…</p>
<ul class="mt-4 space-y-3 text-sm text-zinc-400">
  <li>…</li>
</ul>
<.docs_code label="shell">…</.docs_code>
```

**❌ Bad**

```heex
<%!-- text-base body copy, ad-hoc leading, packed list --%>
<p class="mt-3 text-base leading-relaxed text-zinc-400">Add to your config:</p>
<ul class="mt-2 space-y-2 pl-5 text-sm text-zinc-400">
  <li>…</li>
</ul>
```

**Sweep** (docs prose pages — `docs_*.html.heex` + `connect_llm.html.heex`,
excluding the `docs.html.heex` card-grid index and the `docs_mcp_reference`
reference article):

- `grep -n 'text-base leading-relaxed'` — body copy off the `text-sm` scale.
- `grep -nE '<[uo]l class="[^"]*space-y-(1\.5|2|2\.5)[^"]*text-(sm|zinc)'` —
  prose list containers tighter than `space-y-3`.
- body `<p>`/`<li>` carrying an inline `leading-6`/`leading-8` (the shell
  already supplies `leading-7`; an inline value on body text is either dead or
  a fight with the contract).

**Enforced.** The `docs_layout` `[&_p]:leading-7 [&_li]:leading-7` contract
pins leading structurally — a page physically can't render body text on a
different line-height. Block gaps, font size, and list spacing are this rule
plus the grep sweep above; the `marketing`/`marketing_structural` tests render
every page, so a class that breaks compilation fails there.
