# elixir: model-authored runbook revisions stay in their family

**Rule.** When a model changes an existing runbook, save the next immutable
version under the same slug. Require the exact current `runbook_ref` and the
server-issued definition SHA-256, lock and recheck the family head, and reject a
stale source without reserving an operation or writing a revision. Use draft
creation only for a genuinely new runbook family.

Published discovery and execution stay the default. Draft reads require an
explicit status. Draft execution requires a distinct test mutation with the
exact current ref and hash, and it must enter the same compiler, target
expansion, scope, pack trust, policy, approval, scheduler, runner delivery, and
audit path as a published execution. Persist the execution kind and definition
hash so approvals, audit, recovery, and result views cannot mislabel it.

Testing never publishes or changes draft status. Models do not receive a
publish mutation; a human reviews and publishes the tested version in the
console.

Good: inspect `health-review@4`, pass its returned hash to a draft-revision
mutation, receive `health-review@5` as a draft, test that exact hash through the
normal gates, then hand its review URL to an operator.

Bad: create `health-review-v5`; let ordinary published execution discover a
draft; execute a draft through a scheduler shortcut; accept a ref without its
hash; or let a successful test publish automatically.

**Sweep target.** Search MCP, API, and console runbook mutations for new slugs,
status defaults, execution entry points, publication calls, recovery shapes,
approval context, and audit payloads. Confirm every draft test is identifiable
by kind and definition hash at rest and on model- and operator-facing reads.

**How it is enforced.** Context tests pin same-family versioning, current-head
locking, stale-hash rollback, authorization, and idempotent replay. MCP contract
tests pin explicit draft discovery, published-only ordinary execution, governed
draft test execution and recovery, stable provenance, and absence of a publish
tool.
