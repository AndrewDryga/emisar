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

  alias Emisar.Repo
  alias Emisar.Accounts.Account
  alias Emisar.Billing
  alias Emisar.Runs.RunEvent

  @impl true
  def perform(%Oban.Job{}) do
    Account.Query.all()
    |> Repo.all()
    |> Enum.each(&prune_account/1)

    :ok
  end

  defp prune_account(%Account{} = account) do
    plan = Billing.plan(account.plan) || Billing.plan("free")
    days = plan.audit_retention_days
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)

    {n, _} =
      RunEvent.Query.all()
      |> RunEvent.Query.by_account_id(account.id)
      |> RunEvent.Query.with_run_finished_before(cutoff)
      |> Repo.delete_all()

    if n > 0 do
      require Logger
      Logger.info("action_run_event retention: pruned #{n} events from account #{account.id}")
    end
  end
end
