defmodule Emisar.Runners.Jobs.InstallKeyRetention do
  @moduledoc "Daily cleanup of unused console install keys after their 24-hour expiry."
  use Emisar.Jobs.Job,
    otp_app: :emisar,
    every: :timer.hours(24),
    initial_delay: :timer.minutes(10)

  alias Emisar.{Accounts, Jobs, Runners}

  @impl Emisar.Jobs.Executors.GloballyUnique
  def execute(config) do
    batch_opts = Keyword.take(config, [:batch_size])

    config
    |> Keyword.get(:limit, 100)
    |> Jobs.Sweep.each_row(&list_accounts/2, &sweep_account(&1, batch_opts))
  end

  defp sweep_account(%Accounts.Account{} = account, opts) do
    # Like install-key minting and ring eviction, removing unused bootstrap
    # credentials is silent housekeeping, not a new audit event per page view.
    Runners.delete_expired_install_keys(account.id, opts)
  end

  defp list_accounts(limit, cursor),
    do: Accounts.list_accounts_for_system_sweep(limit: limit, after_account_id: cursor)
end
