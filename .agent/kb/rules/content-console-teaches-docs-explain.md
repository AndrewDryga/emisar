# Console teaches in place; docs explain in depth

**Rule.** The introduction explains what the page is for. An optional side panel
adds practical guidance. Help beside a control explains that decision. Full docs
own setup instructions, detailed behavior, troubleshooting, and reference material.
Give each explanation one home so the reader learns in the order they need it.

## Where help belongs

| Location | Job | Content budget |
|---|---|---|
| Below the page title | Explain what the operator is managing and what they can do here. Introduce an unfamiliar product concept through its purpose. | One or two short sentences. |
| Side panel / docs rail | Explain behavior that helps with the next decision: useful relationships, examples, or common mistakes. | Up to three short paragraphs, only when they add useful information. |
| Beside a control | Explain the value to enter, the setting's effect, or a restriction that affects this choice. | A short hint or an accessible tooltip; show material consequences directly. |
| Confirmation | State the action's scope and consequences before the operator commits. | Enough detail to make the decision deliberately. |
| Empty, error, or permission state | Explain the current state and the next available step. | A short explanation and a relevant action or docs link. |
| Full `/docs/*` page | Teach the complete procedure, mechanics, edge cases, and troubleshooting. | The depth needed to complete the task correctly. |

An unfamiliar name such as Runner or Runbook can need a brief explanation in the
introduction. Familiar concepts such as Team do not need dictionary definitions.
The page must make sense before the reader reaches the side panel. Explain the
page's useful purpose; skip directions that merely describe an obvious button.

A side panel earns its space by helping the operator act. Give it a specific
heading, such as "Working with runners" or "How pack trust works". Add practical
detail beyond the introduction rather than restating the concept. Omit the panel
when the page has no useful extra guidance. Full setup procedures belong in docs.

Keep settings visibly distinct from explanatory help, even when they share a side
column. A setting such as Automatic cleanup keeps its consequences beside its
control and in its confirmation. The reader must not need to consult optional
help to understand a material consequence or recover from the current error.

When the page is empty, let the onboarding state explain the first step. It can
replace the ordinary introduction where that avoids repetition. An error or
permission restriction must describe the actual state, not imply that no data
exists.

## Docs links and narrow layouts

Put the page's main docs link beside the introduction via `<.doc_link>`. If an
onboarding state replaces the introduction, keep the relevant link accessible
there. Link the `/docs/*` page that owns the subject. Avoid repeating that same
general link in the side panel; a specific topic can have its own useful deep
link, such as a connection warning linking to troubleshooting.

Keep the introduction, main docs link, controls, and decision-critical help
available at every screen width. Longer optional help can move below the main
content or into a keyboard-accessible disclosure. It must remain reachable on
narrow screens. A few expandable sentences are appropriate; lengthy procedures
still belong on the public docs page.

## Wording and ownership

Speak to the operator: say what to pick, type, or expect. Briefly explaining an
unfamiliar product concept in the introduction is useful; repeating a field's
label as its definition is not. Field hints should explain the operator's choice,
without justifying our design, narrating internals, or naming the attack a
restriction prevents. Put that reasoning in the owning docs page when useful.

Keep status and shared term explanations in their glossary module
(`EmisarWeb.RunStatuses` is the model), reused by the console and docs. A gated
control uses the shared accessible `<.tooltip>` for a short explanation. Derive
claims from current behavior; do not turn a control into a safety guarantee.

**Why.** A new customer needs to understand the page before using its controls.
A returning operator needs concise help at the decision. Distinct jobs for the
introduction, side panel, and docs serve both readers without repeating a manual
across several surfaces.

✅ Good

- Run detail wraps the status badge in `<.tooltip text={EmisarWeb.RunStatuses.meaning(@run.status)}>` — one sentence, the same string the `/docs/runs` status table renders.
- A page intro ends with its own page's doc: the Runs page links `/docs/runs`, Billing links `/docs/billing` (alongside the `/pricing` compare link, which does a different job).
- A Runners introduction explains what runners do and what the page manages;
  its side panel explains packs, grouping, or connection behavior.
- A Runbooks rail says that stages run in order and a stage must succeed before
  the next stage starts; the introduction already explains what a runbook is.
- Automatic cleanup explains which runners it removes beside the setting; its
  confirmation states the affected scope and what history is retained.
- The install wizard's Resources rail links each install shape's own docs page (host install, containers, Kubernetes, Nomad, autoscaling) instead of one generic guide.
- A callout that teaches a state's consequence ends with the doc link that owns the mechanism (the signed-only callouts link `/docs/signed-dispatch`).
- `Identifier claim` reads "How emisar recognises a returning member. Never their email — people change those." — what it does plus the one consequence, no threat model.
- Entra's hint is "Entra gives every app a different `sub`, so pick `oid` — the same id directory sync uses.": the instruction and why it matters to them; the full identity-convergence argument lives in the Entra guide.

❌ Bad

- A console rail that walks through configuration steps the docs page already owns.
- An introduction assumes the reader knows what a runner is, while the side
  panel supplies the first explanation.
- The introduction and side panel repeat the same definition in different words.
- A page's only docs link disappears with its desktop-only side panel.
- A destructive setting relies on optional side-panel help to explain what it deletes.
- A Runbooks rail that says runbooks turn procedures into executions and drafts
  remain private; neither statement helps the operator build or run one.
- A page intro linking a generically-related page (Runs → quickstart) instead of the page's own doc.
- A status meaning typed inline in a LiveView, drifting from the docs table's wording.
- A "learn more" that opens an in-app manual, modal tour, or second help center instead of the public docs page.
- "The stable, provider-issued claim that identifies a user — restricted to immutable subject identifiers (a mutable claim like email would allow account takeover)." — defines the label, justifies the restriction, names the attack.
- "`sub` is the OIDC standard and the only claim these providers issue for this." — explaining why a one-option list is short is our bookkeeping, not their decision.
- A subtitle describing our implementation ("the issuer we fetch discovery from, and the OAuth client we authenticate as") rather than their inputs.
- A hint that ends in a reasoning chain — "...which is exactly what SCIM provisions on, so sign-in and directory sync converge on one identity".

**Enforced.** Content and UX review on new or changed console help. Check that the
introduction stands alone, the side panel adds useful information, consequences
are beside their decisions, and help stays reachable on narrow screens. These
are judgment checks; a paragraph count or banned-word test does not establish
clarity. Mechanical backstop: each glossary module's unit test asserts a meaning
exists for every enum value it covers (`run_statuses_test.exs` fails the suite on
drift); repeat that pattern for future glossaries.

**Sweep target.** On the changed page, read the introduction, rail, hints,
`<:subtitle>` slots, and callouts in the order a new customer encounters them.
Flag missing orientation, repeated explanations, required guidance hidden in
optional help, field hints that merely define their labels, and prose about our
implementation or threat model. A necessary explanation of a product concept in
the introduction is allowed. Before removing useful reasoning from console help,
check that the owning docs page carries it. Record unrelated pages for a separate
sweep rather than expanding a focused copy change.
