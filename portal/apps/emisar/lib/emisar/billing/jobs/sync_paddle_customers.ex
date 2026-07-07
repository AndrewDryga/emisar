defmodule Emisar.Billing.Jobs.SyncPaddleCustomers do
  @moduledoc """
  Periodic sweep that keeps Paddle Customer records aligned with account owners.
  """
  use Emisar.Jobs.Job,
    otp_app: :emisar,
    every: :timer.minutes(15),
    initial_delay: :timer.minutes(1),
    executor: Emisar.Jobs.Executors.GloballyUnique

  alias Emisar.Billing

  @impl Emisar.Jobs.Executors.GloballyUnique
  def execute(config) do
    :ok = sync_pages(nil, Keyword.get(config, :limit, 100))
  end

  defp sync_pages(after_account_id, limit) do
    {:ok, result} =
      Billing.sync_paddle_customers(limit: limit, after_account_id: after_account_id)

    if result.full? and is_binary(result.last_account_id) do
      sync_pages(result.last_account_id, limit)
    else
      :ok
    end
  end
end
