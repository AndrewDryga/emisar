defmodule Emisar.Catalog.Jobs.PackVersionRetention do
  @moduledoc """
  Daily sweep that deletes pack versions no runner has advertised within an
  account's configured window (`settings.pack_unseen_retention_days`).
  Accounts without the setting are skipped; the per-account sweep audits
  itself only when it removed something.
  """
  use Emisar.Jobs.Job,
    otp_app: :emisar,
    every: :timer.hours(24),
    initial_delay: :timer.minutes(10),
    executor: Emisar.Jobs.Executors.GloballyUnique

  alias Emisar.{Accounts, Catalog}
  require Logger

  @accounts_per_page 100

  @impl Emisar.Jobs.Executors.GloballyUnique
  def execute(config) do
    deleted_count =
      config
      |> Keyword.get(:limit, @accounts_per_page)
      |> sweep_page(nil, 0)

    if deleted_count > 0 do
      Logger.info("pack_version_retention.swept", count: deleted_count)
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

  defp sweep_account(
         %Accounts.Account{settings: %{pack_unseen_retention_days: days}} = account,
         deleted_total
       )
       when is_integer(days) and days > 0 do
    case Catalog.delete_unseen_pack_versions(account.id, days) do
      {:ok, deleted} -> deleted_total + deleted
      {:error, _reason} -> deleted_total
    end
  end

  defp sweep_account(%Accounts.Account{}, deleted_total), do: deleted_total
end
