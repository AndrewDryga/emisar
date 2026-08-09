# elixir: model edits update the single sha-locked draft

**Rule.** A runbook is one row: what is live, plus at most one unpublished
change. When a model edits an existing runbook, it replaces that unpublished
change IN PLACE under the same slug — it never mints a version and never invents
a sibling slug. Require the definition SHA-256 of what the model read (the
unpublished change when there is one, otherwise the live release), compare it
against the locked row inside the transaction, and reject a stale write as
`draft_changed` without reserving an operation or touching content. Use draft
creation only for a genuinely new runbook.

Only the live release executes by default. A published execution names
`slug@release` and that release MUST be the live one — an older number answers
`not_live` rather than silently running current content. Testing the
unpublished change is an explicit guarded mode of `execute_runbook`, not a
second model tool: pass the slug, `allow_draft: true`, and the exact
`definition_sha256` the model consents to run, then enter the same compiler,
target expansion, scope, pack trust, policy, approval, scheduler, runner
delivery, and audit path as a live execution. An execution snapshots the
definition it dispatched and its release number (null for a draft test), so
approvals, audit, recovery, and result views cannot mislabel it or drift when
the runbook row moves on.

Publication is human-only. Models get no publish mutation; an operator reviews
the diff and publishes in the console, which mints the next release.

Good: read `health-review` (live `health-review@4`), pass its returned
`definition_sha256` to `update_runbook_draft`, receive the same slug back with a
new draft hash, run it with `execute_runbook` + `allow_draft: true` + that hash,
then hand the review URL to an operator.

Bad: create `health-review-v5`; save an edit without the sha it read; let
ordinary execution reach an unpublished change; execute `health-review@4` after
v5 went live; add `test_runbook_draft` beside `execute_runbook`; or let a
successful test publish anything.

**Sweep target.** Search MCP, API, and console runbook mutations for new slugs,
version-minting writes, unlocked saves, duplicate execution entry points,
publication calls, recovery shapes, approval context, and audit payloads.
Confirm one execution tool owns both paths, that draft consent is explicit and
content-exact, and that every execution is identifiable by kind, release
number, and definition hash at rest and on model- and operator-facing reads.

**How it is enforced.** Context tests pin in-place draft saves, base-sha
rejection, publish-only-from-draft, release numbering, authorization, and
idempotent replay. MCP contract tests pin explicit draft reads, live-only
default execution, `not_live` for a stale ref, guarded draft execution and
recovery through the same tool, stable provenance, absence of a duplicate test
tool, and absence of a publish tool.
