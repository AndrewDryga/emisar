defmodule Emisar.Workers.BillingSync do
  @moduledoc """
  Hourly reconciliation against Paddle. Catches the rare case where a
  webhook was missed (network blip, transient 5xx) — Paddle is the
  source of truth so we re-fetch every account's subscription.
  """
  use Oban.Worker, queue: :billing, max_attempts: 3

  alias Emisar.{Billing, Repo}
  alias Emisar.Billing.{PaddleClient, Subscription}

  @impl true
  def perform(%Oban.Job{}) do
    Subscription.Query.all()
    |> Repo.all()
    |> Enum.each(&sync/1)

    :ok
  end

  defp sync(%Subscription{paddle_subscription_id: nil}), do: :ok

  defp sync(%Subscription{paddle_subscription_id: sid, account_id: account_id}) do
    case PaddleClient.retrieve_subscription(sid) do
      {:ok, sub} ->
        Billing.upsert_subscription(account_id, %{
          status: sub["status"],
          current_period_end: Billing.extract_next_billed_at(sub)
        })

      {:error, _reason} ->
        :ok
    end
  end
end
