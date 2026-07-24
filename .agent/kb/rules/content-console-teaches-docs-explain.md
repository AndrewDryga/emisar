# Console teaches in place; docs explain in depth

**Rule.** An operator-console surface — page intro, docs rail, empty state, tooltip, callout — states *what a thing is* and *the next action* in a sentence or two, then links the one relevant `/docs/*` page via `<.doc_link>`. The docs page owns the mechanics, edge cases, and reference detail. Console teaching copy never grows into a second manual: a docs rail caps at about three short paragraphs, a status or term explainer is one line sourced from its shared glossary module (`EmisarWeb.RunStatuses` is the model), and a gated control explains itself through the shared `<.tooltip>` in one sentence. Every console page links the docs page that owns its subject — not a generically-related one.

**Why.** Two surfaces explaining the same mechanism drift apart and double the maintenance. Mid-task the console's job is orientation, not education — the shortest true sentence plus the right link beats an inline manual. Single-sourcing the one-liners in glossary modules consumed by both the console and the docs tables keeps the two surfaces honest, and the tooltip physically enforces "most important information only."

✅ Good

- Run detail wraps the status badge in `<.tooltip text={EmisarWeb.RunStatuses.meaning(@run.status)}>` — one sentence, the same string the `/docs/runs` status table renders.
- A page intro ends with its own page's doc: the Runs page links `/docs/runs`, Billing links `/docs/billing` (alongside the `/pricing` compare link, which does a different job).
- The install wizard's Resources rail links each install shape's own docs page (host install, containers, Kubernetes, Nomad, autoscaling) instead of one generic guide.
- A callout that teaches a state's consequence ends with the doc link that owns the mechanism (the signed-only callouts link `/docs/signed-dispatch`).

❌ Bad

- A console rail that walks through configuration steps the docs page already owns.
- A page intro linking a generically-related page (Runs → quickstart) instead of the page's own doc.
- A status meaning typed inline in a LiveView, drifting from the docs table's wording.
- A "learn more" that opens an in-app manual, modal tour, or second help center instead of the public docs page.

**Enforced.** Review-time (content + design-ux hats) on any new console surface. Mechanical backstop: each glossary module's unit test asserts a meaning exists for every enum value it covers (`run_statuses_test.exs` fails the suite on drift); repeat that pattern for future glossaries.
