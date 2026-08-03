# elixir: model-authored runbook revisions stay in their family

**Rule.** When a model changes an existing runbook, save the next immutable
version under the same slug. Require the exact current `runbook_ref` and the
server-issued definition SHA-256, lock and recheck the family head, and reject a
stale source without reserving an operation or writing a revision. Use draft
creation only for a genuinely new runbook family.

Published discovery and execution stay the default. Draft reads require an
explicit status. Draft execution is an explicit guarded mode of
`execute_runbook`, not a second model tool: require the exact current ref plus
`allow_draft: true`, then enter the same compiler, target expansion, scope,
pack trust, policy, approval, scheduler, runner delivery, and audit path as a
published execution. A version ref already pins immutable content, so the
server records the definition hash rather than asking the caller to echo it.
Persist the execution kind and definition hash so approvals, audit, recovery,
and result views cannot mislabel it.

Testing never publishes or changes draft status. Models do not receive a
publish mutation; a human reviews and publishes the tested version in the
console.

Good: inspect `health-review@4`, pass its returned hash to a draft-revision
mutation, receive `health-review@5` as a draft, then call `execute_runbook`
with that exact ref and `allow_draft: true` before handing its review URL to an
operator.

Bad: create `health-review-v5`; let ordinary published execution discover a
draft; add `test_runbook_draft` beside `execute_runbook`; execute a draft
without explicit consent or through a scheduler shortcut; or let a successful
test publish automatically.

**Sweep target.** Search MCP, API, and console runbook mutations for new slugs,
status defaults, duplicate execution entry points, publication calls, recovery
shapes, approval context, and audit payloads. Confirm one execution tool owns
both paths, draft consent is explicit, and every draft run is identifiable by
kind and definition hash at rest and on model- and operator-facing reads.

**How it is enforced.** Context tests pin same-family versioning, current-head
locking, stale-hash rollback, authorization, and idempotent replay. MCP contract
tests pin explicit draft discovery, published-only default execution, guarded
draft execution and recovery through the same tool, stable provenance, absence
of a duplicate test tool, and absence of a publish tool.
