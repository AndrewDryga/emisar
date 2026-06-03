---
name: investigate
description: Root-cause a crash, exception, stacktrace, failing test, or wrong behavior in portal/ — reproduce, read the real error, trace to the actual cause, propose the minimal fix. Use when something raises/fails/misbehaves and you need the cause, not a guess (Ecto changeset/constraint errors, Oban job failures, LiveView/MCP errors, runner-socket issues, flaky tests).
effort: medium
argument-hint: "<the error, failing test, or symptom>"
allowed-tools: Read, Grep, Glob, Bash
---

# Investigate (find the cause, not a symptom)

Discipline beats guessing. Do **not** propose a fix until you can point at the
line that's wrong and say why. Never edit a test to make a real failure pass.

## Method

1. **Reproduce.** Get the exact failing command and run it: `mix test path:line`,
   the LiveView action, the MCP call, the failing context function in `iex -S mix`.
   No repro → you're guessing.
2. **Read the WHOLE error.** The full stacktrace, the changeset errors, the SQL.
   The first frame in *our* code (not a dep) is usually the spot. Don't skim to the
   summary line.
3. **Locate + read the code.** Open the failing function and the data it touched.
   Confirm the contract of anything you're unsure of (`/verify-api`) — half of
   "bugs" are an assumed return shape or arg that was never real.
4. **One hypothesis, then confirm it** against the code/data before fixing. If the
   evidence doesn't match, the hypothesis is wrong — don't fix anyway.
5. **Minimal fix** at the cause. Then add a **regression test** that fails before /
   passes after (and the denial / cross-account variant if it's a context bug, §7).

## emisar error catalogue (where to look first)

- **`{:error, %Ecto.Changeset{}}`** — read `changeset.errors`. A `*_constraint`
  error (unique/foreign_key) means the DB rejected it: the matching
  `unique_constraint`/`foreign_key_constraint` is missing from the Changeset, or the
  migration lacks the index/FK. A `validate_*` error is just invalid input.
- **`{:error, :unauthorized}`** — the subject lacks the permission (Authorizer role
  list), or `ensure_has_permissions` is checking the wrong one.
- **`{:error, :not_found}`** — genuinely missing, OR `Authorizer.for_subject` scoped
  it out (cross-account) — check the subject's account vs the row's.
- **Oban job keeps retrying** — read `max_attempts` and the `perform` error; a job
  that isn't idempotent (IL-13) corrupts state on retry. Check args are string-keyed.
- **LiveView** — value missing/doubled on load → `mount` runs twice (IL-18); a
  silent form failure → check the `{:error, changeset}` branch is handled, not the UI.
- **MCP** — a doubled action → idempotency key (see `controllers/mcp/idempotency.ex`);
  an auth error → the subject built at the MCP boundary.
- **Runner socket** — state not updating → the `Runners.apply_state/mark_*` path
  (§1.4); a crash shouldn't take down other runners (IL-17).
- **Flaky test** — a cross-process race: `$callers` not inherited, or async side
  effects not made sync in test (the `notify_approvers_async?` flag pattern). Never
  `Process.sleep` it away — `assert_receive` with a timeout.

## Output

`Cause: <file:line — what's wrong and why>` → `Fix: <the minimal change>` →
`Regression test: <what it asserts>`. If you can't isolate it, say what you ruled
out and what you'd instrument next — don't ship a guess.
