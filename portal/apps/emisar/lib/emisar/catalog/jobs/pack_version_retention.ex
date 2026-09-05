defmodule Emisar.Catalog.Jobs.PackVersionRetention do
  @moduledoc """
  Daily catalog bookkeeping. For every account it first deletes the retired
  pack versions no runner advertises anymore
  (`Catalog.delete_unadvertised_retired_pack_versions/1`), then — only where
  automatic cleanup is on, which `Catalog.pack_retention_days/1` decides — the
  versions no runner has advertised within the account's window. Each sweep
  audits each nonempty committed batch, not an account-sized transaction.
  """
  use Emisar.Jobs.Job,
    otp_app: :emisar,
    every: :timer.hours(24),
    initial_delay: :timer.minutes(10)

  alias Emisar.{Accounts, Catalog, Jobs}
  require Logger

  @accounts_per_page 100

  @impl Emisar.Jobs.Executors.GloballyUnique
  def execute(config) do
    batch_opts = Keyword.take(config, [:batch_size])

    deleted_count =
      config
      |> Keyword.get(:limit, @accounts_per_page)
      |> Jobs.Sweep.reduce_pages(0, &list_accounts/2, &sweep_account(&1, &2, batch_opts))

    if deleted_count > 0 do
      Logger.info("pack_version_retention.swept", count: deleted_count)
    end

    :ok
  end

  defp sweep_account(%Accounts.Account{} = account, deleted_total, batch_opts) do
    deleted_total + retired_removed(account, batch_opts) + unseen_removed(account, batch_opts)
  end

  defp retired_removed(%Accounts.Account{id: account_id}, batch_opts) do
    case Catalog.delete_unadvertised_retired_pack_versions(account_id, batch_opts) do
      {:ok, deleted} -> deleted
      {:error, _reason} -> 0
    end
  end

  defp unseen_removed(%Accounts.Account{} = account, batch_opts) do
    with {:ok, days} <- Catalog.pack_retention_days(account),
         {:ok, deleted} <- Catalog.delete_unseen_pack_versions(account.id, days, nil, batch_opts) do
      deleted
    else
      {:error, _reason} -> 0
    end
  end

  defp list_accounts(limit, cursor),
    do: Accounts.list_accounts_for_system_sweep(limit: limit, after_account_id: cursor)
end
