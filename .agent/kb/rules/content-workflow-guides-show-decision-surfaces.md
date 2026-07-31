# Workflow guides show every decision-bearing surface

**Rule.** A product workflow guide must visibly teach every authoring surface that changes the
result. For a complex editor, introduce each decision in task order, explain the consequence in
plain language, and place a current screenshot or complete canonical example beside it. An overview
crop does not stand in for controls below the fold.

The minimum runbook sweep is: run-time inputs, stage and step order, targets and actions, argument
bindings, extracted outputs, success conditions, and failure or wait behavior. Apply the same test
to other workflow editors by listing the decisions an operator must make before the artifact can be
used.

**Why.** A guide can name a capability in reference prose or JSON and still strand a reader in the
editor. Readers follow the walkthrough first. If the walkthrough skips the controls that determine
success, they either accept unsafe defaults or have to reverse-engineer the schema from a different
section. A large screenshot compounds the problem: it proves the section exists without making its
fields readable.

## Good

- The walkthrough defines a step, then shows arguments, outputs, conditions, and an optional wait in
  the same order as the editor.
- One seeded example supplies the values shown in the UI captures, canonical JSON, and result page.
- Each screenshot is anchored to the smallest complete section and its caption states the decision
  being made.

## Bad

- One stage screenshot cuts off the lower half of the step while the prose claims the step is fully
  documented.
- Outputs and waits appear only in the schema reference after the task walkthrough has ended.
- Separate screenshots use unrelated actions and values, leaving no coherent procedure to follow.

## How it is enforced

Review the rendered desktop and mobile guide, not only its template. The marketing test pins each
decision-bearing heading and image path. Capture drivers use stable section IDs so screenshots fail
when the authoring surface moves or disappears.

**Sweep target.** For every workflow guide, compare its numbered walkthrough with the editor's
sections and canonical schema. Flag a customer-facing field group that changes execution but appears
only below a screenshot crop, only in reference prose, or only in raw JSON.
