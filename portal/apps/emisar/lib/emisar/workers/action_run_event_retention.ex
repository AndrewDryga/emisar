defmodule Emisar.Workers.ActionRunEventRetention do
  @moduledoc """
  Nightly job that prunes action-run events (streamed progress chunks + state
  transitions) once the run that produced them ages past the account's plan
  retention window. A single streaming run can emit thousands of these rows, so
  without this sweep `action_run_events` grows unbounded even though the
  human-facing `audit_events` are capped by `Workers.AuditRetention`.

  Retention is keyed on the parent run's `finished_at`, not the event's own
  `inserted_at`: events for a still-running run are kept regardless of age. The
  account-paging, bounded-batch delete, and cursor continuation live in
  `Workers.AccountRetention`; this worker just supplies what to prune.
  """
  # `unique` on the cursor key keeps a slow chain and the next nightly tick from
  # double-walking the account set: a follow-up for a cursor already in flight
  # collapses onto the existing job. Idempotent either way (the prunable set only
  # shrinks) — this just spares the wasted scan + `:audit`-queue contention.
  use Oban.Worker,
    queue: :audit,
    max_attempts: 2,
    unique: [period: :infinity, states: :incomplete, keys: [:after_account_id]]

  alias Emisar.{Runs, Workers.AccountRetention}

  @impl true
  def perform(%Oban.Job{args: args}) do
    AccountRetention.run(args, %AccountRetention.Spec{
      worker: __MODULE__,
      prunable_ids: &Runs.RunEvent.Query.prunable_ids/3,
      delete_by_ids: &Runs.RunEvent.Query.by_ids/1,
      label: "action_run_event retention"
    })
  end
end
