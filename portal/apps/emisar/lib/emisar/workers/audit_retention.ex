defmodule Emisar.Workers.AuditRetention do
  @moduledoc """
  Nightly job that prunes audit events older than each account's plan retention
  window. The account-paging, bounded-batch delete, and cursor continuation live
  in `Workers.AccountRetention`; this worker just supplies what to prune (audit
  events, keyed on the event's own age).
  """
  # `unique` on the cursor key keeps a slow chain and the next nightly tick from
  # double-walking the account set: a follow-up for a cursor already in flight
  # collapses onto the existing job. Idempotent either way (the prunable set only
  # shrinks) — this just spares the wasted scan + `:audit`-queue contention.
  use Oban.Worker,
    queue: :audit,
    max_attempts: 2,
    unique: [period: :infinity, states: :incomplete, keys: [:after_account_id]]

  alias Emisar.{Audit, Workers.AccountRetention}

  @impl true
  def perform(%Oban.Job{args: args}) do
    AccountRetention.run(args, %AccountRetention.Spec{
      worker: __MODULE__,
      prunable_ids: &Audit.Event.Query.prunable_ids/3,
      delete_by_ids: &Audit.Event.Query.by_ids/1,
      label: "audit retention"
    })
  end
end
