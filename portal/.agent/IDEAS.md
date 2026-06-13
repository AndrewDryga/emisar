# portal — IDEAS

Product ideas as short implementation sketches. **Not auto-implemented:** a human
details and approves an idea, then it *moves* into `TASKS.md`. The work loop never
pulls work from here. See root `AGENTS.md` → "The `.agent/` working state".

## Ideas

Surfaced during the 2026-06-12 product-readiness pass — each needs a human call
(design asset, scale judgment, or "do we want this?") before it becomes a `[ ]`.

- **Per-page OpenGraph images.** The layout already supports an `og_image` override;
  only the generic `/images/og/emisar-product.webp` is used everywhere. Bespoke share
  cards for home, pricing, the use-case stories, and the comparison pages would lift
  social CTR. *Needs a designer to produce the images*; the wiring (per-page `og_image`
  in `marketing_controller.ex`, mirroring the breadcrumb derivation) is ~20 min.

- **`og:type=article` + `Article`/`TechArticle` JSON-LD on docs + use-cases.** Minor SEO
  refinement; only worth it with real `datePublished`/`dateModified` — so it needs a
  source of truth for doc dates (git mtime? front-matter?) before it's honest.

- **Runners cursor composite index `(account_id, group, name)`.** The runners list sorts
  `(group, name, id)` but only `(account_id, group)` + `(account_id, name)` exist, so a
  large fleet sorts by name in memory. Deferred as over-indexing for the common
  bounded-fleet case — revisit if an Enterprise account runs hundreds of runners.

- **Symptom-indexed "Common errors" doc/FAQ.** "Runner won't connect", "pack_untrusted",
  "denied by policy", "stuck pending approval" — one page keyed on the symptom, linking
  to the feature docs, with `FAQPage` JSON-LD. Judged borderline-redundant with the home
  FAQ + `docs_runners` + the docs-index "Stuck?" CTA — a human should decide if the
  consolidation is worth a new page.

- **Resolve runner ids → names in the audit-detail scope chip + policy-denial reason.**
  Today a runner-scoped policy shows the runner *id* (scope chip) or "this runner"
  (denial reason). A name would read better but needs a cross-context Runners lookup at
  render time (and a deleted-runner fallback) — small, but a deliberate coupling call.
