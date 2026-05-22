defmodule Emisar.Workers.BillingSync do
  @moduledoc """
  Hourly reconciliation against Stripe. Catches the rare case where a
  webhook was missed (network blip, transient 5xx) — Stripe is the
  source of truth so we re-fetch every account's subscription.
  """
  use Oban.Worker, queue: :billing, max_attempts: 3

  alias Emisar.{Billing, Repo}
  alias Emisar.Billing.{StripeClient, Subscription}

  @impl true
  def perform(%Oban.Job{}) do
    Subscription
    |> Repo.all()
    |> Enum.each(&sync/1)

    :ok
  end

  defp sync(%Subscription{stripe_subscription_id: nil}), do: :ok

  defp sync(%Subscription{stripe_subscription_id: sid, account_id: account_id}) do
    case StripeClient.retrieve_subscription(sid) do
      {:ok, sub} ->
        Billing.upsert_subscription(account_id, %{
          status: sub["status"],
          current_period_end:
            case sub["current_period_end"] do
              nil -> nil
              n when is_integer(n) -> DateTime.from_unix!(n)
            end
        })

      {:error, _reason} ->
        :ok
    end
  end
end
