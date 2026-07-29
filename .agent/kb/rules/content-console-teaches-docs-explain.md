# Console teaches in place; docs explain in depth

**Rule.** An operator-console surface — page intro, docs rail, empty state, tooltip, callout — states *what a thing is* and *the next action* in a sentence or two, then links the one relevant `/docs/*` page via `<.doc_link>`. The docs page owns the mechanics, edge cases, and reference detail. Console teaching copy never grows into a second manual: a docs rail caps at about three short paragraphs, a status or term explainer is one line sourced from its shared glossary module (`EmisarWeb.RunStatuses` is the model), and a gated control explains itself through the shared `<.tooltip>` in one sentence. Every console page links the docs page that owns its subject — not a generically-related one.

**And it speaks to the operator, not about our design.** Console help says what to pick, type, or expect. It does not define the term in the label, justify why the options are limited, narrate what emisar does internally, or name the attack a restriction prevents. That reasoning is real and belongs in the docs page that owns it — a field hint is not where we defend a decision. The tell: a hint an engineer would write in a design review, reaching the operator unedited.

**Why.** Two surfaces explaining the same mechanism drift apart and double the maintenance. Mid-task the console's job is orientation, not education — the shortest true sentence plus the right link beats an inline manual. Single-sourcing the one-liners in glossary modules consumed by both the console and the docs tables keeps the two surfaces honest, and the tooltip physically enforces "most important information only."

✅ Good

- Run detail wraps the status badge in `<.tooltip text={EmisarWeb.RunStatuses.meaning(@run.status)}>` — one sentence, the same string the `/docs/runs` status table renders.
- A page intro ends with its own page's doc: the Runs page links `/docs/runs`, Billing links `/docs/billing` (alongside the `/pricing` compare link, which does a different job).
- The install wizard's Resources rail links each install shape's own docs page (host install, containers, Kubernetes, Nomad, autoscaling) instead of one generic guide.
- A callout that teaches a state's consequence ends with the doc link that owns the mechanism (the signed-only callouts link `/docs/signed-dispatch`).
- `Identifier claim` reads "How emisar recognises a returning member. Never their email — people change those." — what it does plus the one consequence, no threat model.
- Entra's hint is "Entra gives every app a different `sub`, so pick `oid` — the same id directory sync uses.": the instruction and why it matters to them; the full identity-convergence argument lives in the Entra guide.

❌ Bad

- A console rail that walks through configuration steps the docs page already owns.
- A page intro linking a generically-related page (Runs → quickstart) instead of the page's own doc.
- A status meaning typed inline in a LiveView, drifting from the docs table's wording.
- A "learn more" that opens an in-app manual, modal tour, or second help center instead of the public docs page.
- "The stable, provider-issued claim that identifies a user — restricted to immutable subject identifiers (a mutable claim like email would allow account takeover)." — defines the label, justifies the restriction, names the attack.
- "`sub` is the OIDC standard and the only claim these providers issue for this." — explaining why a one-option list is short is our bookkeeping, not their decision.
- A subtitle describing our implementation ("the issuer we fetch discovery from, and the OAuth client we authenticate as") rather than their inputs.
- A hint that ends in a reasoning chain — "...which is exactly what SCIM provisions on, so sign-in and directory sync converge on one identity".

**Enforced.** Review-time (content + design-ux hats) on any new console surface. Mechanical backstop: each glossary module's unit test asserts a meaning exists for every enum value it covers (`run_statuses_test.exs` fails the suite on drift); repeat that pattern for future glossaries.

**Sweep target.** Read console hints, `<:subtitle>` slots, and callout bodies aloud as if to an admin mid-task. Flag: a sentence defining the term in its own label; "would allow/let" plus an attack name; "restricted to", "immutable", "by construction"; first-person implementation ("we fetch", "we authenticate"); and any clause after "so that"/"which means" that argues rather than instructs. Before deleting the reasoning, check the owning docs page carries it — move it there if not.
