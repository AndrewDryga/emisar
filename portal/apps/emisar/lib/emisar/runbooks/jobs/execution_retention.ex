defmodule Emisar.Runbooks.Jobs.ExecutionRetention do
  @moduledoc """
  Daily sweep that prunes completed runbook executions past account retention.
  """
  use Emisar.Jobs.Job,
    otp_app: :emisar,
    every: :timer.hours(24),
    initial_delay: :timer.minutes(8)

  alias Emisar.{Accounts, Billing, Jobs, Repo, Runbooks}
  require Logger

  @accounts_per_page 100
  @batch_size 1_000

  @impl Emisar.Jobs.Executors.GloballyUnique
  def execute(config) do
    deleted_count =
      config
      |> Keyword.get(:limit, @accounts_per_page)
      |> Jobs.Sweep.reduce_pages(0, &list_accounts/2, &sweep_account/2)

    if deleted_count > 0 do
      Logger.info("runbook_execution_retention.swept", count: deleted_count)
    end

    :ok
  end

  defp sweep_account(%Accounts.Account{} = account, deleted_total) do
    retention_days = Billing.account_audit_retention_days(account.id)
    cutoff = DateTime.utc_now() |> DateTime.add(-retention_days * 86_400, :second)

    deleted_total + delete_in_batches(account.id, cutoff, 0)
  end

  # Smaller batches than the flat-row sweeps: each delete cascades through the
  # execution's stages and items to the action runs beneath them, so one batch
  # touches far more rows than it names.
  defp delete_in_batches(account_id, cutoff, deleted_total) do
    queryable = Runbooks.RunbookExecution.Query
    ids = account_id |> queryable.prunable_ids(cutoff, @batch_size) |> Repo.all()
    {deleted_count, _} = ids |> queryable.by_ids() |> Repo.delete_all()
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
