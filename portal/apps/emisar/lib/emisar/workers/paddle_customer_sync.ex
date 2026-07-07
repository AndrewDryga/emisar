defmodule Emisar.Workers.PaddleCustomerSync do
  @moduledoc """
  Keeps Paddle Customer records aligned with local account ownership:
  customer email = stable active owner email, name = account name, custom_data
  carries the account id. The Billing context owns the domain selection; the
  worker owns Oban pagination and one-bad-account isolation.
  """
  use Oban.Worker,
    queue: :billing,
    max_attempts: 3,
    unique: [period: 60, states: :incomplete, keys: [:account_id, :after_account_id]]

  alias Emisar.Billing
  require Logger

  @impl true
  def perform(%Oban.Job{args: %{"account_id" => account_id}}) when is_binary(account_id) do
    case Billing.sync_paddle_customer_for_account(account_id) do
      {:ok, _customer_id, _account} ->
        :ok

      {:error, reason} when reason in [:no_billing_contact, :not_found] ->
        :ok

      {:error, reason} ->
        Logger.warning("paddle_customer_sync.account_failed",
          account_id: account_id,
          error: inspect(redacted_paddle_error(reason))
        )

        :ok
    end
  end

  def perform(%Oban.Job{args: args}) do
    with {:ok, result} <- Billing.sync_paddle_customers(args) do
      maybe_continue(result)
    end
  end

  defp maybe_continue(%{full?: true, last_account_id: account_id, limit: limit})
       when is_binary(account_id) do
    {:ok, _job} =
      %{"after_account_id" => account_id, "limit" => limit}
      |> __MODULE__.new()
      |> Oban.insert()

    :ok
  end

  defp maybe_continue(_result), do: :ok

  defp redacted_paddle_error({:http, status, _body}), do: {:http, status}
  defp redacted_paddle_error(reason), do: reason
end
