---
name: oban
description: Build or review an Oban background job / scheduled sweep in portal/ (lib/emisar/workers/) the emisar way — idempotent, string-key args, IDs not structs (IL-13), correct queue + max_attempts, enqueued from a context, testable. Use when adding/changing a worker or cron sweep, or debugging job retries.
effort: medium
argument-hint: "<worker name or job to build/review>"
allowed-tools: Read, Grep, Glob, Bash, Write, Edit
---

# Oban jobs

Workers live in `lib/emisar/workers/`. Read the existing ones first and match them —
`approval_expiry`, `audit_retention`, `billing_sync`, and `run_dispatch_timeout`
are the templates.

## Shape

```elixir
defmodule Emisar.Workers.RunDispatchTimeout do
  use Oban.Worker, queue: :default, max_attempts: 2

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id}}) do
    # ... idempotent work ...
  end
end
```
Queues in use: **`:default`** and **`:billing`** (read the Oban config in `config/`
for the full list + the cron/`Plugins.Cron` schedule before adding a queue or a
scheduled job — don't invent a queue name).

## Iron Law IL-13 (non-negotiable)

1. **Idempotent.** A job runs ≥1 times (retries, at-least-once). Check current state
   before acting — re-expiring an already-expired approval, re-dispatching a finished
   run, double-charging in `billing_sync` are all bugs. Make the effect a no-op the
   second time.
2. **String-key args.** Pattern-match `%{"run_id" => id}` — args round-trip through
   the DB as JSON; atom keys won't match.
3. **IDs, not structs.** Store `run_id`, not `%Run{}`. The struct is stale by the
   time the job runs and isn't serializable.

## Wiring

- **Enqueue from a context**, not the web layer: `%{"run_id" => id} |> Worker.new() |> Oban.insert()`.
- The job is an authenticated process (§1.4): if it calls a context, wrap with
  `Subject.system/1` — these are the no-`%Subject{}` internal helpers.
- Scheduled sweeps (expiry, retention, health) go through the Oban cron plugin in
  `config/`, calling an internal context sweeper (`Approvals.expire_overdue_requests/1`).

## Testing (§7)

- Assert enqueue without running: `Oban.Testing` `assert_enqueued(worker: W, args: %{...})`
  (confirm `use Oban.Testing` / testing mode is set in the test config — `/verify-api`).
- Run the job directly: `perform_job(W, %{"run_id" => id})`.
- Cover the **retry/idempotency** path: run `perform` twice, assert the second is a
  no-op. For a sweep, cover the happy + nothing-to-do cases.

## Finish

`cd portal && mix compile --warnings-as-errors && mix format && mix test <worker test>`.
