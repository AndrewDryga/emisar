defmodule Emisar.Workers.BillingSync do
  @moduledoc """
  Hourly reconciliation against Paddle. Catches the rare case where a
  webhook was missed (network blip, transient 5xx) — Paddle is the
  source of truth so we re-fetch every account's subscription.
  """
  use Oban.Worker, queue: :billing, max_attempts: 3
  alias Emisar.{Billing, Repo}
  alias Emisar.Billing.{PaddleClient, Subscription}
  require Logger

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

      {:error, reason} ->
        # Don't fail the whole sweep — a single bad subscription must
        # not block the rest — but surface every failure to Logger so
        # a permanent Paddle credential revocation (or one tenant whose
        # subscription was deleted out from under us) doesn't go
        # invisible. Sentry's Logger backend picks this up automatically.
        Logger.warning("billing_sync.retrieve_failed",
          paddle_subscription_id: sid,
          account_id: account_id,
          error: inspect(reason)
        )

        :ok
    end
  end
end
