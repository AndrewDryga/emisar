---
name: elixir-testing
description: Write or improve ExUnit tests for portal/ the emisar way — DataCase/ConnCase, the real fixtures in test/support, and the mandatory happy / denial / cross-account paths (§7). Use when adding tests for a context/job/LiveView, or when a change is missing its denial + cross-account coverage.
effort: medium
argument-hint: "<context / worker / module to test>"
allowed-tools: Read, Grep, Glob, Bash, Write, Edit
---

# Tests (the emisar way)

This project uses **plain ExUnit + Ecto sandbox + hand-written fixtures**. There is
**no Mox, no ExMachina, no StreamData** in the dep stack — do not introduce them or
write tests that assume them (`/tooling-verify-api`: test with what's here). Read a sibling
test (`test/emisar/runs_test.exs`, `policies_test.exs`) and match it.

## Setup

- Domain: `use Emisar.DataCase, async: true`. Web: `use EmisarWeb.ConnCase`.
- Fixtures: `test/support/fixtures.ex` — `owner_subject_fixture/1`, `subject_for/2`,
  role fixtures. Build a **real `%Subject{}`**, not a stub. Add a fixture there if the
  context needs one; don't inline ad-hoc setup that duplicates an existing fixture.

## The three paths (non-negotiable — §7, IL-3)

Every context function covers:
1. **Happy** — the authorized subject gets `{:ok, …}`.
2. **Denial** — a role *without* the permission gets `{:error, :unauthorized}`. A
   write isn't done without this.
3. **Cross-account** — account A's subject cannot see/touch account B's row:
   `{:error, :not_found}`.

## Doubling third-party calls (no Mox)

Per IL-19, vendor APIs (Paddle, mailer) are wrapped behind a project module. Test by
swapping/configuring that wrapper, or with a config flag — the codebase already uses
the `notify_approvers_async?`-style flag to make async side effects synchronous in
test. Follow that pattern; don't reach for a mocking library.

## Concurrency

- `async: true` is the default — keep it. Anything that spawns a DB-touching process
  must inherit `$callers` or be made synchronous in test (the config-flag pattern).
- **No `Process.sleep`** for synchronization — `assert_receive {…}, 500` across
  process boundaries.

## Jobs / LiveView

- Jobs: call `JobModule.execute([])` or `execute(keyword_config)` directly. Cover
  the idempotency path (run twice → second is a no-op), plus pagination/batches for sweeps.
- LiveView: `Phoenix.LiveViewTest` (`live/2`, `render_click`, `render_submit`); assert
  the authorized + denied event paths (IL-15).

## Run

`cd portal && mix test <path>` (or `<path>:<line>`). Green + the denial/cross-account
cases present = done (IL-20).
