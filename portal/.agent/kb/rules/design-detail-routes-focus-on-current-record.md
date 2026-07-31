# Detail routes focus on the current record

## Rule

An individual detail route answers one question: what happened in this selected
record? Keep recent sibling history and short product guidance on its parent
index or start surface, where operators choose what to inspect next.

Render each ordered workflow unit once. Its heading carries status and mode; its
body carries items, evidence, attempts, and results. Do not precede the same
stages with a second stage strip that repeats their titles and states.

For executable work, show a bounded escaped output tail inline for every action
attempt. Keep the complete raw run behind a link for deeper inspection. Fetch
tails in one authorized bounded read, cap each action independently, and fail
closed if any requested run is outside the subject's account or runner scope.
Never weaken output retention, redaction, or sensitive-value masking to populate
the preview.

User-authored operational instructions are an artifact, not page chrome. Render
them through the shared artifact panel so Markdown cannot blend into headings,
help text, or form controls.

## Why

Duplicated workflow summaries make operators compare two representations of the
same state. Sibling history on a detail page pushes the selected result farther
away and makes a long execution look like a runbook index. A raw-output link
alone hides the evidence operators opened the execution to review.

## Good

- The runbook index has a quiet right rail with short guidance and the account's
  five recent runbook executions.
- The start surface keeps its current frozen plan, execution guidance, and
  recent executions in a secondary rail after the primary form on narrow screens.
- An execution shows its result banner, then each stage once with stage status,
  action status, visible arguments, bounded output, and the full-run link.
- Progress chunks are escaped, stderr is distinguished, and one noisy action
  cannot crowd another action out of the batch preview.
- Operator Markdown sits in `<.artifact_panel>`.

## Bad

- `Stages` summary cards followed by sections with the same stage titles.
- `Recent executions` below an individual execution.
- An action row that says only `View raw action output`.
- One unbounded event query per action, or a batch read that silently drops a
  hidden run while returning the visible ones.
- Authored Markdown rendered as ordinary page prose above a form.

## Enforcement

LiveView tests pin the parent rail, the absence of history and duplicate stage
copy on execution routes, escaped inline output, and cross-account exclusion.
Context tests pin per-run caps, chronological order, permission denial, and
fail-closed mixed-access reads. Review sweeps execution detail pages for sibling
history and repeated workflow-unit headings.
