defmodule Emisar.Runners.Jobs.InactiveRunnerRetention do
  @moduledoc """
  Hourly sweep that soft-deletes runners cleanly offline longer than an
  account's configured window. `Runners.inactive_retention_hours/1` decides
  what each account's stored setting means, so accounts with cleanup off are
  skipped; the per-account sweep audits itself only when it removed something.
  """
  use Emisar.Jobs.Job,
    otp_app: :emisar,
    every: :timer.hours(1),
    initial_delay: :timer.minutes(10)

  alias Emisar.{Accounts, Jobs, Runners}
  require Logger

  @accounts_per_page 100

  @impl Emisar.Jobs.Executors.GloballyUnique
  def execute(config) do
    deleted_count =
      config
      |> Keyword.get(:limit, @accounts_per_page)
      |> Jobs.Sweep.reduce_pages(0, &list_accounts/2, &sweep_account/2)

    if deleted_count > 0 do
      Logger.info("inactive_runner_retention.swept", count: deleted_count)
    end

    :ok
  end

  defp sweep_account(%Accounts.Account{} = account, deleted_total) do
    with {:ok, hours} <- Runners.inactive_retention_hours(account),
         {:ok, deleted} <- Runners.delete_inactive_runners(account.id, hours) do
      deleted_total + deleted
    else
      {:error, _reason} -> deleted_total
    end
  end

  defp list_accounts(limit, cursor),
    do: Accounts.list_accounts_for_system_sweep(limit: limit, after_account_id: cursor)
end
