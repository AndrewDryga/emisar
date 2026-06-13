---
name: iron-review
description: Review a diff or the working tree against the Emisar Iron Laws (IL-1…IL-20) — the mechanical Credo checks plus the judgment checks a static analyzer can't do. Use when reviewing portal/ Elixir before a PR, after a refactor, or to double-check context/query/changeset/LiveView changes. Reports law · file:line · fix.
effort: medium
argument-hint: "[path or git ref, default = working tree]  [--fix]"
allowed-tools: Read, Grep, Glob, Bash
---

# Iron Law review

Check `portal/` Elixir against the Iron Laws in `portal/AGENTS.md`. The custom
Credo checks (`Emisar.Checks.*`) cover the mechanical subset — start by running
`mix credo` from `portal/` and treating any finding as a failure; this skill
**adds the judgment laws** — including IL-15 and IL-16, whose safety depends on
where a value came from, which a static check deliberately can't decide. Default scope: the working
tree (`git diff` + untracked). A path or git ref narrows it.

Read-only by default. With `--fix`, apply only the unambiguous mechanical fixes
(see end) and re-verify; never "fix" a judgment finding without showing it first.

## Step 1 — mechanical checks (Credo)

Run `mix credo` from `portal/` and treat every finding as a failure — fix them all before reading further. The custom `Emisar.Checks.*` AST checks are the mechanical source of truth (IL-1, IL-2, IL-6, IL-7, IL-8, IL-12, IL-13, IL-14 + the house rules) and **replaced the old hand-grep battery**, so there is nothing to grep by hand. Details: `portal/AGENTS.md` → Enforcement.

## Step 2 — judgment checks (read the changed bodies)

For each changed context / query / changeset / authorizer / LiveView / MCP /
controller file, read it and check:

- **IL-3** — every *public* context fn takes `%Subject{}` as the last required
  arg and calls `ensure_has_permissions/2` **before** any DB call. (Internal §1.4
  helpers are exempt — confirm they're truly internal and unexposed.)
- **IL-4** — `Authorizer.for_subject(query, subject)` sits immediately before
  every `Repo.fetch`/`list`/`fetch_and_update` in a context.
- **IL-5** — public reads/writes return tagged tuples; no bare struct/`nil`.
- **IL-9** — authorizers expose `build(Schema, :verb)` accessors, clause all
  roles, and the new authorizer is in `auth/authorizer.ex`'s `@authorizers`.
- **IL-10** — no `Repo.preload/2` in a context (route via Query `preloads/0`),
  except a post-commit email helper.
- **IL-13** — Oban `perform` matches **string** keys; args carry IDs, not structs;
  the job is safe to run twice.
- **IL-14** — `String.to_atom/1` only on code literals / bounded sets; **never** on
  request params, runner output, or MCP/LLM input (atom-table DoS). Trace the arg to
  its source before clearing it.
- **IL-16** — `raw/1` only on app-generated / known-safe HTML (server-rendered QR
  SVG, sanitized markdown); **never** on runner output, runbook, or pack text
  (stored XSS). Confirm the source.
- **IL-15** — every LiveView `handle_event` / MCP action / controller action that
  mutates passes the subject into a context call (no trusting mount/connect).
- **IL-17** — long-lived processes are under a supervisor (no bare `start_link`).
- **IL-18** — LiveView: no unconditional `Repo`/context read in `mount`
  (`assign_async` or `connected?` + cache); `stream/3` for lists that can grow;
  `connected?(socket)` guard before `subscribe`; no `assign_new` for per-mount
  values.
- **IL-11** — no shim/flag/deprecated-kept/corrective-migration-on-unshipped.
- **IL-20** — if the change claims "done", `mix compile --warnings-as-errors && mix test` output is present.

## Step 3 — report

One block per finding, ordered by law number, then severity:

```
IL-4 · BLOCKER · lib/emisar/widgets.ex:42
  list_widgets/2 calls Repo.list without Authorizer.for_subject above it — cross-account leak.
  Fix: pipe `|> Authorizer.for_subject(subject)` before `|> Repo.list(...)`.
```

Lead with a one-line verdict (`N blockers, M suggestions`). If clean, say so in
one line — don't pad. Findings that need a human call (is this list large enough
to need a stream?) are SUGGESTIONS with the question stated, not BLOCKERS.

## `--fix` scope (mechanical only)

Apply without asking only the unambiguous, behavior-preserving rewrites:
`Repo.get(X, id)` → `Schema.Query.by_id/2` + `Repo.fetch/3`; `:float`→`:decimal` on
a money field; moving an inline `where`/`order_by`/`join` into the Schema.Query
module. Re-run `mix credo` and `mix compile` after. Everything else — a missing
`for_subject` scope, a `String.to_atom`, a `raw/1`, any authz-shape gap — is
**report-only**: it needs a human to confirm intent/source first (e.g.
`String.to_existing_atom` raises if the atom was never defined).
