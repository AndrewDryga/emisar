---
name: elixir-context-fn
description: Add a read, write, or action to an existing Emisar context using its Query, Subject, Authorizer, tagged returns, and denial/isolation tests.
effort: medium
argument-hint: "<Context>.<function> e.g. Runbooks.archive_runbook"
allowed-tools: Read, Grep, Glob, Bash, Write, Edit
---

# Add a context function

Read portal/AGENTS.md and sections 1, 2, 4, 5, and 7 of
portal/.agent/kb/rules/elixir-layered-contexts.md as relevant to the operation.
Read the target context and match its existing functions.

For Subject-gated public APIs, Subject is the last required positional argument.
Check permission before database access, scope with Authorizer.for_subject
immediately before the Repo call, and return the documented tagged tuple.
Read section 1.2 for self-service and section 1.4 for already-authorized internal
helpers; do not apply a generic template over those explicit exceptions.

Choose the existing Repo operation for the contract: fetch for a tagged row, list
for a paginated result, insert for creation, fetch_and_update for guarded single-row
mutations, and Multi for multi-row composition. Confirm signatures in source.
Queries own predicates; changesets own casts, validations, and state transitions.

Audit writes belong in the transaction; external side effects belong after the
outer commit. Use named per-event broadcast helpers. Do not place audit insertion
inside an after_commit callback or nest after_commit under another transaction.

Reuse permission accessors; introduce a new one only for a new capability and wire
its role grants. State the function's contract in its documentation.
Cover happy, denial, and cross-account behavior for both reads and writes.
Use focused checks while working; the lead owns the final ./run gate portal and
the relevant trust-boundary review.
