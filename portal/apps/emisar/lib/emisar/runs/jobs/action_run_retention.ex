defmodule Emisar.Runs.Jobs.ActionRunRetention do
  @moduledoc """
  Daily sweep that prunes terminal action runs past account retention.
  """
  use Emisar.Jobs.Job,
    otp_app: :emisar,
    every: :timer.hours(24),
    initial_delay: :timer.minutes(5),
    executor: Emisar.Jobs.Executors.GloballyUnique

  alias Emisar.{Accounts, Billing, Repo, Runs}
  require Logger

  @accounts_per_page 100
  @batch_size 5_000

  @impl Emisar.Jobs.Executors.GloballyUnique
  def execute(config) do
    deleted_count =
      config
      |> Keyword.get(:limit, @accounts_per_page)
      |> sweep_page(nil, 0)

    if deleted_count > 0 do
      Logger.info("action_run_retention.swept", count: deleted_count)
    end

    :ok
  end

  defp sweep_page(limit, after_account_id, deleted_total) do
    accounts =
      Accounts.list_accounts_for_system_sweep(
        limit: limit,
        after_account_id: after_account_id
      )

    deleted_total = Enum.reduce(accounts, deleted_total, &sweep_account/2)

    if length(accounts) == limit do
      sweep_page(limit, List.last(accounts).id, deleted_total)
    else
      deleted_total
    end
  end

  defp sweep_account(%Accounts.Account{} = account, deleted_total) do
    retention_days = Billing.account_audit_retention_days(account.id)
    cutoff = DateTime.utc_now() |> DateTime.add(-retention_days * 86_400, :second)

    deleted_total + delete_in_batches(account.id, cutoff, 0)
  end

  defp delete_in_batches(account_id, cutoff, deleted_total) do
    ids = account_id |> Runs.ActionRun.Query.prunable_ids(cutoff, @batch_size) |> Repo.all()
    {deleted_count, _} = ids |> Runs.ActionRun.Query.by_ids() |> Repo.delete_all()
    deleted_total = deleted_total + deleted_count

    if length(ids) == @batch_size do
      delete_in_batches(account_id, cutoff, deleted_total)
    else
      deleted_total
    end
  end
end
