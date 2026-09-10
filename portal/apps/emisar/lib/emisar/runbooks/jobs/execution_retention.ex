defmodule Emisar.Runbooks.Jobs.ExecutionRetention do
  @moduledoc """
  Daily sweep that prunes completed runbook executions past account retention.
  """
  use Emisar.Jobs.Job,
    otp_app: :emisar,
    every: :timer.hours(24),
    initial_delay: :timer.minutes(8)

  alias Emisar.{Accounts, Billing, Jobs, Runbooks}
  require Logger

  @accounts_per_page 100
  # Smaller batches than the flat-row sweeps: each delete cascades through the
  # execution's stages and items to the action runs beneath them, so one batch
  # touches far more rows than it names.
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

    deleted_total +
      Jobs.Sweep.delete_in_batches(
        Runbooks.RunbookExecution.Query,
        account.id,
        cutoff,
        @batch_size
      )
  end

  defp list_accounts(limit, cursor),
    do: Accounts.list_accounts_for_system_sweep(limit: limit, after_account_id: cursor)
end
