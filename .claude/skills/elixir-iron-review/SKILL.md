---
name: elixir-iron-review
description: Review a diff or the working tree against the Emisar Iron Laws (IL-1…IL-20) — the mechanical Credo checks plus the judgment checks a static analyzer can't do. Use when reviewing portal/ Elixir before a PR, after a refactor, or to double-check context/query/changeset/LiveView changes. Reports law · file:line · fix.
effort: medium
argument-hint: "[path or git ref, default = working tree]  [--fix]"
allowed-tools: Read, Grep, Glob, Bash, Write, Edit
---

# Iron Law review

Check `portal/` Elixir against the Iron Laws in `portal/AGENTS.md`. The custom
Credo checks (`Emisar.Checks.*`) cover the mechanical subset; this skill
**adds the judgment laws** — including IL-15 and IL-16, whose safety depends on
where a value came from, which a static check deliberately can't decide. Default scope: the working
tree (`git diff` + untracked). A path or git ref narrows it.

Read-only by default. A fix request or `--fix` authorizes repairs within its scope.
Gather evidence for judgment findings before changing behavior; ask only for a
material decision or missing authority.

## Step 1 — mechanical checks (Credo)

Use existing gate/Credo evidence when it covers the unchanged reviewed tree;
otherwise run focused Credo on changed Elixir files. Report findings during a
review; repair them only when fixes are authorized. The final Portal gate still
includes full Credo. Details: portal/.agent/kb/rules/elixir-layered-contexts.md
section Enforcement.

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
  roles, and the new authorizer is in `auth/permissions.ex`'s `@authorizers`.
- **IL-10** — Subject-gated context reads route preloads through Query `preloads/0`.
  An internal, no-Subject, already-authorized path holding a struct may use
  `Repo.preload/2` for its parent association (post-commit email helpers or the
  runner-register billing check). Confirm that distinction before reporting a finding.
- **IL-13** — recurrent jobs derive work from durable rows, keep each tick
  idempotent, and stay safe if a previous tick partially completed.
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
- **IL-20** — if the change claims "done", green `./run gate portal` output is present.

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

## Fix scope

Trace return contracts and data provenance before repairing a finding. Moving an
inline query into its Query module can preserve behavior; replacing Repo.get with
Repo.fetch changes the return shape, and changing a money field may require a
production migration. Follow the actual caller and applied-migration contracts.
For authorized security fixes, establish intended scope and test the denial path;
do not require another confirmation merely because the finding involves judgment.
Run focused checks after repair and the canonical final gate on the finished tree.
