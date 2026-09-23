---
name: debug-investigate
description: Root-cause a crash, exception, stacktrace, failing test, or wrong behavior in portal/ — reproduce, read the real error, trace to the actual cause, propose the minimal fix. Use when something raises/fails/misbehaves and you need the cause, not a guess (Ecto changeset/constraint errors, recurrent job failures, LiveView/MCP errors, runner-socket issues, flaky tests).
effort: medium
argument-hint: "<the error, failing test, or symptom>"
allowed-tools: Read, Grep, Glob, Bash
---

# Investigate (find the cause, not a symptom)

Discipline beats guessing. Do **not** propose a fix until you can point at the
line that's wrong and say why. Never edit a test to make a real failure pass.

## Method

Reproduce the failure before theorizing: the exact failing command
(`./run test portal <path>:<line>`), the LiveView action, the MCP call, or the
failing context function in `iex -S mix`. Read the full error (stacktrace,
changeset errors, SQL) and the code and data it touched; confirm any contract
you're unsure of with `/tooling-verify-api`. Fix only once the evidence confirms
the cause, fix it at the cause, and add a **regression test** that fails before
and passes after (plus the denial / cross-account variant for a context bug, §7).

## emisar error catalogue (where to look first)

- **`{:error, %Ecto.Changeset{}}`** — read `changeset.errors`. A `*_constraint`
  error (unique/foreign_key) means the DB rejected it: the matching
  `unique_constraint`/`foreign_key_constraint` is missing from the Changeset, or the
  migration lacks the index/FK. A `validate_*` error is just invalid input.
- **`{:error, :unauthorized}`** — the subject lacks the permission (Authorizer role
  list), or `ensure_has_permissions` is checking the wrong one.
- **`{:error, :not_found}`** — genuinely missing, OR `Authorizer.for_subject` scoped
  it out (cross-account) — check the subject's account vs the row's.
- **Recurrent job keeps failing** — read the `execute/1` error and the durable rows
  it polls; a job that isn't idempotent (IL-13) corrupts state when a tick repeats.
- **LiveView** — value missing/doubled on load → `mount` runs twice (IL-18); a
  silent form failure → check the `{:error, changeset}` branch is handled, not the UI.
- **MCP** — a doubled action → the operation-id recovery path
  (`get_operation` / `MCPOperations.fetch_recovery`); MCP mutations have no
  idempotency key. An auth error → the subject built at the MCP boundary.
- **Runner socket** — state not updating → the runner-socket state helpers
  (`Runners.apply_state`, `connect_runner`, `disconnect_runner`,
  `record_heartbeat`; §1.4); a crash shouldn't take down other runners (IL-17).
- **Flaky test** — a cross-process race: `$callers` not inherited, or async side
  effects not made sync in test (the `notify_approvers_async?` flag pattern). Never
  `Process.sleep` it away — `assert_receive` with a timeout.

## Output

`Cause: <file:line — what's wrong and why>` → `Fix: <the minimal change>` →
`Regression test: <what it asserts>`. If you can't isolate it, say what you ruled
out and what you'd instrument next — don't ship a guess.
