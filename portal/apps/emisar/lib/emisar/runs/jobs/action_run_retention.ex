defmodule Emisar.Runs.Jobs.ActionRunRetention do
  @moduledoc """
  Daily sweep that prunes terminal action runs past account retention.
  """
  use Emisar.Jobs.Job,
    otp_app: :emisar,
    every: :timer.hours(24),
    initial_delay: :timer.minutes(5),
    executor: Emisar.Jobs.Executors.GloballyUnique

  alias Emisar.{Accounts, Billing, Jobs, Repo, Runs}
  require Logger

  @accounts_per_page 100
  @batch_size 5_000

  @impl Emisar.Jobs.Executors.GloballyUnique
  def execute(config) do
    deleted_count =
      config
      |> Keyword.get(:limit, @accounts_per_page)
      |> Jobs.Sweep.reduce_pages(0, &list_accounts/2, &sweep_account/2)

    if deleted_count > 0 do
      Logger.info("action_run_retention.swept", count: deleted_count)
    end

    :ok
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

  defp list_accounts(limit, cursor),
    do: Accounts.list_accounts_for_system_sweep(limit: limit, after_account_id: cursor)
end
