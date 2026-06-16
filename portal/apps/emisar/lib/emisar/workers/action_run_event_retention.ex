defmodule Emisar.Workers.ActionRunEventRetention do
  @moduledoc """
  Nightly job that prunes action-run events (streamed progress chunks +
  state transitions) once the run that produced them ages past the
  account's plan retention window. A single streaming run can emit
  thousands of these rows, so without this sweep `action_run_events`
  grows unbounded even though the human-facing `audit_events` are capped
  by `Workers.AuditRetention`.

  Retention is keyed on the parent run's `finished_at`, not the event's
  own `inserted_at`: events for a still-running (or never-finished) run
  are kept regardless of age. Each account is processed independently so
  a slow one can't starve the others, mirroring `Workers.AuditRetention`.
  """
  use Oban.Worker, queue: :audit, max_attempts: 2
  alias Emisar.{Accounts, Billing, Repo, Runs}
  require Logger

  # A single account can carry a huge backlog (thousands of progress chunks per
  # streaming run), so we delete in bounded batches by id rather than one
  # unbounded DELETE that would take a long lock and bloat the table.
  @batch_size 5_000

  @impl true
  def perform(%Oban.Job{}) do
    # Deliberately `all()`, not `not_deleted()`: a tombstoned account's
    # run events still occupy space and age past retention all the same.
    Accounts.Account.Query.all()
    |> Repo.all()
    |> Enum.each(&prune_account/1)

    :ok
  end

  defp prune_account(%Accounts.Account{} = account) do
    plan = Billing.plan(Billing.account_plan(account)) || Billing.plan("free")
    cutoff = DateTime.utc_now() |> DateTime.add(-plan.audit_retention_days * 86_400, :second)

    pruned = delete_in_batches(account.id, cutoff, 0)

    if pruned > 0 do
      Logger.info(
        "action_run_event retention: pruned #{pruned} events from account #{account.id}"
      )
    end
  end

  # Delete ≤ @batch_size prunable events by id, looping until a batch comes back
  # short (the prunable set is drained). Stable across iterations: new events
  # are only ever written for current runs, never for already-finished ones.
  defp delete_in_batches(account_id, cutoff, total) do
    ids = Runs.RunEvent.Query.prunable_ids(account_id, cutoff, @batch_size) |> Repo.all()
    {n, _} = Runs.RunEvent.Query.by_ids(ids) |> Repo.delete_all()

    if length(ids) < @batch_size do
      total + n
    else
      delete_in_batches(account_id, cutoff, total + n)
    end
  end
end
