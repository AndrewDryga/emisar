# Rule: the marketing hero is one treatment from the `marketing_heading` scale — never a per-page `!text-*` override

**Rule.** Every PRIMARY / top-nav marketing page opens with the SAME hero, and its
type comes entirely from the `:display` scale in
`EmisarWeb.CoreComponents.marketing_heading/1` — never a per-page size or leading
override. The primary-hero contract:

| Element | Class |
|---|---|
| Section padding | `py-24 sm:py-32` |
| Eyebrow (where present) | `<p class="text-base font-semibold text-brand-400">` |
| Title | `<.marketing_heading tag="h1" scale={:display} class="mt-2">` — size + leading live in the scale (`text-4xl/[1.1] tracking-[-0.035em] sm:text-6xl/[1.1] md:text-7xl/[1.1]`), never re-specified per page |
| Lede | `max-w-2xl` (`<p class="mt-8 max-w-2xl text-lg leading-8 text-zinc-400">`) |

Pages on this `:display` tier: home, security, pricing, about, zero_trust, docs
(index), changelog, how_it_works, trust, guides_index, use_cases, packs. A **dark-band
explainer** (how_it_works/trust/guides_index) keeps its `bg-[#07080a]` band + bottom
border but the SAME padding + scale. A **rich hero** (home, packs) may add content
below the lede (a demo card, a command box) but the title/padding/eyebrow are
unchanged — the extra content lives in the SAME `max-w-2xl` column.

The `:hero` scale (`text-4xl md:text-5xl`, one step smaller) is the QUIETER tier —
docs SUB-pages (quickstart, runners, …) and the three `max-w-3xl` narrow compare
pages. Don't promote those to `:display`; don't demote a primary page to `:hero`.

**Why.** The scale exists precisely so "headings at the same level look identical
across pages" (its moduledoc). When each page re-specifies size/leading with a
`!text-*/[1.1]` override, the scale stops being the source of truth and the pages
drift — which is exactly what happened: five pages carried three different `!text-*`
overrides, so same-tier heroes rendered at 5xl/6xl/7xl with 1.0 vs 1.1 leading, and
the founder caught it page by page. One scale = one place to tune, zero drift, and a
new page is consistent by construction.

**✅ Good**

```heex
<%!-- primary hero — everything from the scale, nothing overridden --%>
<section class="py-24 sm:py-32">
  <div class="mx-auto max-w-4xl px-6 lg:px-8">
    <p class="text-base font-semibold text-brand-400">Use cases</p>
    <.marketing_heading tag="h1" scale={:display} class="mt-2">
      Most days it saves an hour. Some days it saves the night.
    </.marketing_heading>
    <p class="mt-8 max-w-2xl text-lg leading-8 text-zinc-400 text-pretty">…</p>
  </div>
</section>
```

**❌ Bad**

```heex
<%!-- a per-page override fights the scale → the drift this rule exists to stop --%>
<section class="py-16 sm:py-24">
  <p class="text-sm font-semibold text-brand-400">Use cases</p>
  <.marketing_heading
    tag="h1"
    scale={:display}
    class="mt-2 !text-4xl/[1.1] sm:!text-5xl/[1.1] md:!text-6xl/[1.1]"
  >
    …
  </.marketing_heading>
</section>
```

To change the display hero SIZE or LEADING, edit the one `marketing_heading_scale(:display)`
clause in `core_components.ex` — not a page.

**How it's enforced.** Review + the two tests that pin the scale string:
`test/emisar_web/components/marketing_heading_test.exs` (the `:display`/`:hero`/`:section`
ramp) and `test/emisar_web/marketing_test.exs` (the home + docs/quickstart `<h1>` class
prefix). Change the scale and both go red, so the scale and its tests move in the same
change. NOT Credo — `Emisar.Checks.*` read `.ex`/`.exs`, not `.html.heex`, so a per-page
`!text-*` in a template is invisible to them (and a class-string grep-test is the
discouraged anti-pattern §8). When you touch a marketing hero, eyeball a rendered crop
against `/security` (the reference). Related: `.agent/rules/design-ui-shared-components.md`
(one component per shape), `.agent/rules/design-system.md` (the type scale itself).
