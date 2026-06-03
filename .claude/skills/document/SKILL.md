---
name: document
description: Write @moduledoc / @doc for portal/ Elixir in the house style — purpose and contract, not narration of the code. Use when a public module or function lacks docs, or after adding a context function, so the next reader knows the contract (args, return shape, required permission) without reading the body.
effort: low
argument-hint: "<module or function to document>"
allowed-tools: Read, Grep, Glob, Bash, Edit
---

# Document (contract, not narration)

Good docs state what a reader can't get faster from the signature: the contract and
the why. Bad docs restate the code. Per the prime directive, **comments/docs explain
why and what-it-guarantees, never what-the-code-literally-does** — and no bloat: a
doc that says nothing is worse than none.

Read the function and its tests first and document **what it actually does** — never
infer behavior you didn't confirm (`/verify-api`).

## `@moduledoc`

One short paragraph: the module's responsibility and its boundary. For a **context
module**, say it's the public/authorization boundary for that domain. For a Query/
Changeset/Schema, one line is plenty (the conventions already define their role).

## `@doc` on public functions

State the contract:
- what it does (one line),
- the **`%Subject{}` / permission** it requires (e.g. "requires `manage` on …"),
- the **return shape**, matching the real code: `{:ok, row} | {:error, :not_found | :unauthorized}` etc.

```elixir
@doc """
Archives a runbook. Requires `manage` on runbooks; scoped to the subject's account.

Returns `{:ok, runbook}` or `{:error, :not_found | :unauthorized}`.
"""
def archive_runbook(id, %Subject{} = subject)
```

## Internal / private

The §1.4 internal helpers get a one-line `@doc "Internal — <who calls it>."`; truly
private/uninteresting functions get `@doc false` or nothing. Don't write paragraphs
for a one-liner.

## Don't

- No `@doc` that paraphrases the function body line by line.
- No "this is the new/refactored version" notes (IL-11 — there's no legacy).
- No examples that aren't real/tested.

After editing, `cd portal && mix compile --warnings-as-errors` (doc attributes on a
private/undefined function warn).
