defmodule Emisar.Runners.Jobs.InactiveRunnerRetention do
  @moduledoc """
  Hourly sweep that soft-deletes runners cleanly offline longer than an
  account's configured window (`settings.runner_inactive_retention_hours`).
  Accounts without the setting are skipped; the per-account sweep audits
  itself only when it removed something.
  """
  use Emisar.Jobs.Job,
    otp_app: :emisar,
    every: :timer.hours(1),
    initial_delay: :timer.minutes(10),
    executor: Emisar.Jobs.Executors.GloballyUnique

  alias Emisar.{Accounts, Runners}
  require Logger

  @accounts_per_page 100

  @impl Emisar.Jobs.Executors.GloballyUnique
  def execute(config) do
    deleted_count =
      config
      |> Keyword.get(:limit, @accounts_per_page)
      |> sweep_page(nil, 0)

    if deleted_count > 0 do
      Logger.info("inactive_runner_retention.swept", count: deleted_count)
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
         %Accounts.Account{settings: %{runner_inactive_retention_hours: hours}} = account,
         deleted_total
       )
       when is_integer(hours) and hours > 0 do
    case Runners.delete_inactive_runners(account.id, hours) do
      {:ok, deleted} -> deleted_total + deleted
      {:error, _reason} -> deleted_total
    end
  end

  defp sweep_account(%Accounts.Account{}, deleted_total), do: deleted_total
end
