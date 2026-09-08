# Console teaches in place; docs explain in depth

**Rule.** The introduction explains what the page is for. An optional side panel
adds practical guidance. Help beside a control explains that decision. Full docs
own setup instructions, detailed behavior, troubleshooting, and reference material.
Give each explanation one home so the reader learns in the order they need it.

Connection and installation screens are an exception: their main content includes
a short, complete numbered setup path with copyable commands and configuration.
Do not replace a required setup step with a docs link. The full guide owns the
longer explanations, uncommon variants, and troubleshooting.

For a prefilled connection recipe, show required configuration directly after the
integration is selected. Do not hide it behind an accordion or a separate generation
button. Collapse only optional guidance.

For a content-only review, preserve the existing layout, components, typography,
icons, and link treatment. Shortening labels or reducing redundant links does not
authorize new cards, accordions, grouping, or interaction patterns. Propose a
design change separately instead of including it in a copy edit.

Keep peer field labels short enough for one line at their intended control
width; use "Max parallel actions" for the runbook stage limit. Related fields
share a row when their actual container has room and wrap on narrower panels.
Help-rail links inherit the rail's body size, not the larger page default.
Do not repeat a full plan in a separate sidebar summary; keep decision-critical
approval requirements with the main plan.

Runbook output controls choose a stream and an extractor. JSON validity, pointer
resolution, and schema-validated stdout mechanics belong in the runbook docs,
not conditional notices beside the picker. Keep actual validation and execution
errors visible; do not replace them with generic advance warnings.

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

When permissions change what a page offers, write the whole introduction for that
role or use one coherent introduction for everyone. Do not append a second list
of capabilities to a shared list; explain the page in natural prose.

A side panel earns its space by helping the operator act. Give it a specific
heading, such as "Working with runners" or "How pack trust works". Add practical
detail beyond the introduction rather than restating the concept. Omit the panel
when the page has no useful extra guidance. Full setup procedures belong in docs.
Keep product-specific requirements and consequences; omit generic reminders to
review carefully when they add no useful information.

Lead with the common task, then briefly cover variants that change the decision.
On Approvals, explain reviewing a single action before the whole-runbook case;
the less common case must not become the page's main explanation.

Write that guidance for the current page's decisions, not as a reusable product
overview with different nouns. Agents help can explain connection ownership,
runner access, and revocation; Runners help can explain installing packs,
grouping, and connectivity. Do not repeat the generic action-and-policy overview
on both. Related views of the same task may share guidance, and shared terms
should remain consistent; page-specific help does not require novel definitions.

Match detail to the current task. On Runbooks, the list explains the purpose,
creation options (including asking an LLM), and draft/publish behavior. Stage
ordering, parallel actions, outputs, and success conditions belong in the editor
where the operator chooses them, not in the list's introductory help.

Onboarding and management need different help even when they concern the same
entity. On Connect an agent, "What's an AI agent?" can introduce familiar apps,
what connecting makes possible, and a useful first prompt. The agents list owns
access, key rotation, and revocation guidance. Do not reuse a management rail on
the connect page just because both views share a component. Lead setup choices
with familiar app names and plain instructions, before OAuth or stdio mechanics.

Beginner-friendly means clear language, not trivial work. When illustrating the
product's value, show meaningful operational work or a complete workflow, such as
fleet-wide investigation through recovery and verification. Reserve tiny checks
for a first-connection test; keep capability claims tied to available actions.

Keep settings visibly distinct from explanatory help, even when they share a side
column. A setting such as Automatic cleanup keeps its consequences beside its
control and in its confirmation. The reader must not need to consult optional
help to understand a material consequence or recover from the current error.

When the page is empty, let the onboarding state explain the first step. It can
replace the ordinary introduction where that avoids repetition. An error or
permission restriction must describe the actual state, not imply that no data
exists.
When access hides part of a page, name what remains available: "You can view only
the default policy," not just "You can view the default policy."
Attach access restrictions to the affected section instead of letting a notice
blend into the page introduction. On Policy, no runner access shows a neutral
Read-only lock badge beside Default policy and replaces that section's usual
subtitle with the restriction. Ordinary restricted access is not an amber warning.
Align a title-adjacent badge's text baseline with the title, not the centers of
their boxes. An icon badge must expose the label's baseline while keeping its
icon centered; a pixel translation does not correct a baseline mismatch.
Likewise, a text-only section action beside a title aligns by text baseline,
not the bottom edges of its smaller line box. Use the shared section header's
`actions_align={:baseline}` and a plain inline link, with its trailing icon in
the same text flow. Apply this pattern to matching console headers rather than
adding page-specific `!items-*` overrides. Headers with subtitles or button
actions retain their existing layout. A class assertion is not visual proof:
review the actual text baseline when rendered verification is available.
A read-only empty collection
uses the shared compact empty-state treatment, not a second help paragraph in the
same style. Keep its label short; the surrounding help already explains behavior.
A single-line read-only placeholder should match the corresponding add row's
compact height, not occupy a larger panel than the editable state.

For an empty optional editor collection, the section heading and an available
Add control already explain the state and next action. Do not add a redundant
"No inputs" or "No extracted outputs" line above that control. Keep a concise
empty-state label in read-only views where adding is unavailable. Retain help
that adds a real requirement or consequence, such as a required minimum value,
a prerequisite for adding an item, or what happens when no conditions are set.
This rule does not replace whole-page onboarding, filtered-empty, or error states.

Keep public help visible in permission and empty-scope states. Restrict the data
and controls the user cannot access, not general explanations or documentation
links. On narrow screens, place that help after the access message.

## Docs links and narrow layouts

Put the page's main docs link beside the introduction via `<.doc_link>`. If an
onboarding state replaces the introduction, keep the relevant link accessible
there. Link the `/docs/*` page that owns the subject. Avoid repeating that same
general link in the side panel; a specific topic can have its own useful deep
link, such as a connection warning linking to troubleshooting.

Do not link away to content the page already provides. Billing already shows
the plans, so its introduction keeps Billing docs and omits Compare plans.

For optional how-to or troubleshooting help in a side panel, explain the behavior
first and finish the paragraph with a descriptive docs link, such as "How to group
runners" or "Troubleshoot an offline runner". This distinguishes instructions from
an in-app action. Keep inline links when their job is to define a term or cite a
reference.

When prose names an in-app destination, such as Team, make that name an inline
navigation link without an external-link icon. Keep it in the current tab and
current account. Use the docs-link treatment for public documentation instead.

Keep punctuation adjacent to inline link text, including in table empty states:
`>runner's page</.link>.`, not a newline before `</.link>.`. Whitespace inside the
link becomes a visible gap before punctuation. Fix the template boundary rather
than hiding it with CSS or globally trimming slot content.

Keep the introduction, main docs link, controls, and decision-critical help
available at every screen width. Longer optional help can move below the main
content or into a keyboard-accessible disclosure. It must remain reachable on
narrow screens. A few expandable sentences are appropriate; lengthy procedures
still belong on the public docs page.

## Wording and ownership

Role descriptions and role-change confirmations name the role in a complete
sentence, such as "Billing managers can…" or "Viewers have read-only access…".
The body must make sense independently of its heading. Reuse the canonical role
description, retaining explicit access exclusions and privileged-action consequences.
Keep role capabilities separate from guidance about editing a member's access.
Admin and Operator role-change confirmations put that guidance in its own paragraph
and point to Team's Actions → Edit access, not the choices inside the editor.
Do not carry roster-menu instructions into invite or connection-default role pickers.

Keep table cell values concise. An explanation can be longer on the detail page:
use `self` in the audit table's Target column and `Same as actor` in event details.
When an audit target is the current account, use `account` in the table and
`Current account` in event details, omitting the redundant account-ID row.
The table's `account` label uses the same muted styling as `self`, without a tooltip.
Match the account kind and ID; keep other targets and stored audit records unchanged.
Audit actor and target labels show a known name or email, never a UUID fallback.
For former members, use identity evidence already recorded in this account's
readable audit history, not their current identity in another account. If no
name is available, show `Name unavailable`. Keep IDs in explicit detail facts
and exports; do not rewrite historical events to change their display labels.

Speak to the operator: say what to pick, type, or expect. Briefly explaining an
unfamiliar product concept in the introduction is useful; repeating a field's
label as its definition is not. Field hints should explain the operator's choice,
without justifying our design, narrating internals, or naming the attack a
restriction prevents. Put that reasoning in the owning docs page when useful.

Plain language does not require a longer paraphrase of a precise, familiar term:
use "exact content hash" rather than "exact contents, not just the version number."
For pack cleanup, say "no longer reported by runners" rather than "unseen"; keep
the period options short ("After 30 days") once the hint explains what they measure.
Keep setting hints short; put routine schedules and return-state mechanics
in linked docs while retaining material deletion effects and off-setting exceptions
beside the control.

Packs cleanup is an explicit compact-copy exception: use a one-sentence summary
with an inline Details link in the same paragraph. The docs own trust-decision removal and the retired
version exception; the cleanup confirmation retains the exact deletion scope.

On Packs, use the short button label `Remove` consistently; the confirmation
title names the pack or version. Explain that removing a catalog record does not
uninstall the pack from runners, but omit the obvious audit-history reminder.
Describe retirement as following `critical changes`, not a `critical fix` or
`security fix`. Trust confirmations retain the fact that policies still apply.

Do not append "in this account" to ordinary account-scoped copy. Name scope when
it distinguishes the action from a narrower selection or another account, not
when it only repeats the page's context.

Keep status and shared term explanations in their glossary module
(`EmisarWeb.RunStatuses` is the model), reused by the console and docs. A gated
control uses the shared accessible `<.tooltip>` for a short explanation. Derive
claims from current behavior; do not turn a control into a safety guarantee.

Use **offline** for a runner without a connection to emisar, including cleanup
options, confirmations, and result messages. Do not call that state **inactive**:
it can imply a connected runner with no recent activity. Internal field and event
names are not customer terminology and do not need renaming for a copy change.
Do not relabel a broader unavailable-target state as offline. A runbook group
without eligible targets can be empty, removed, disabled, outside the user's
access, or offline. Say "No runners available in {group}" unless the actual
connection state establishes a more specific cause.

**Why.** A new customer needs to understand the page before using its controls.
A returning operator needs concise help at the decision. Distinct jobs for the
introduction, side panel, and docs serve both readers without repeating a manual
across several surfaces.

✅ Good

- Run detail wraps the status badge in `<.tooltip text={EmisarWeb.RunStatuses.meaning(@run.status)}>` — one sentence, the same string the `/docs/runs` status table renders.
- A page intro ends with its own page's doc: the Runs page links `/docs/runs`, Billing links `/docs/billing` without a redundant plan-comparison link.
- A Runners introduction explains what runners do and what the page manages;
  its side panel explains packs, grouping, or connection behavior.
- The Runbooks list explains drafts and publishing; the editor explains stage
  ordering beside the Stages controls.
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
