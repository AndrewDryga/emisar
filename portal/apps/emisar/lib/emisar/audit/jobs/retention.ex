defmodule Emisar.Audit.Jobs.Retention do
  @moduledoc """
  Periodic sweep that prunes audit events past their per-row retention horizon.
  """
  use Emisar.Jobs.Job,
    otp_app: :emisar,
    every: :timer.hours(1),
    initial_delay: :timer.minutes(4),
    executor: Emisar.Jobs.Executors.GloballyUnique

  alias Emisar.{Accounts, Audit, Repo}
  require Logger

  @accounts_per_page 100
  @batch_size 5_000

  @impl Emisar.Jobs.Executors.GloballyUnique
  def execute(config) do
    config
    |> Keyword.get(:limit, @accounts_per_page)
    |> sweep_page(nil)
  end

  defp sweep_page(limit, after_account_id) do
    accounts =
      Accounts.list_accounts_for_system_sweep(
        limit: limit,
        after_account_id: after_account_id
      )

    Enum.each(accounts, &sweep_account/1)

    if length(accounts) == limit do
      sweep_page(limit, List.last(accounts).id)
    else
      :ok
    end
  end

  defp sweep_account(%Accounts.Account{} = account) do
    now = DateTime.utc_now()
    count = delete_in_batches(account.id, 0)

    if count > 0 do
      Logger.info("audit retention: pruned #{count} events from account #{account.id}")
      Audit.record(Audit.Events.audit_retention_swept(account.id, count, now))
    end
  end

  defp delete_in_batches(account_id, total) do
    ids = account_id |> Audit.Event.Query.prunable_ids(@batch_size) |> Repo.all()
    {count, _} = ids |> Audit.Event.Query.by_ids() |> Repo.delete_all()

    if length(ids) < @batch_size do
      total + count
    else
      delete_in_batches(account_id, total + count)
    end
  end
end
