defmodule Emisar.Runs.Jobs.EventRetention do
  @moduledoc """
  Periodic sweep that prunes run progress events past account retention.
  """
  use Emisar.Jobs.Job,
    otp_app: :emisar,
    every: :timer.hours(1),
    initial_delay: :timer.minutes(5),
    executor: Emisar.Jobs.Executors.GloballyUnique

  alias Emisar.{Accounts, Billing, Repo, Runs}

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
    retention_days = Billing.account_audit_retention_days(account.id)
    cutoff = DateTime.utc_now() |> DateTime.add(-retention_days * 86_400, :second)

    delete_in_batches(account.id, cutoff)
  end

  defp delete_in_batches(account_id, cutoff) do
    ids = account_id |> Runs.RunEvent.Query.prunable_ids(cutoff, @batch_size) |> Repo.all()
    {_count, _} = ids |> Runs.RunEvent.Query.by_ids() |> Repo.delete_all()

    if length(ids) == @batch_size do
      delete_in_batches(account_id, cutoff)
    else
      :ok
    end
  end
end
