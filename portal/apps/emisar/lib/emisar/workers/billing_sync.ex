defmodule Emisar.Workers.BillingSync do
  @moduledoc """
  Hourly reconciliation against Paddle. Catches the rare case where a
  webhook was missed (network blip, transient 5xx) — Paddle is the
  source of truth so we re-fetch every account's subscription.
  """
  use Oban.Worker, queue: :billing, max_attempts: 3
  alias Emisar.{Billing, Repo}
  require Logger

  @impl true
  def perform(%Oban.Job{}) do
    Billing.Subscription.Query.all()
    |> Repo.all()
    |> Enum.each(&sync/1)

    :ok
  end

  defp sync(%Billing.Subscription{paddle_subscription_id: nil}), do: :ok

  defp sync(%Billing.Subscription{
         paddle_subscription_id: paddle_subscription_id,
         account_id: account_id
       }) do
    case Billing.PaddleClient.retrieve_subscription(paddle_subscription_id) do
      {:ok, subscription_data} ->
        # Only set current_period_end when Paddle reports one: a non-renewing sub
        # (canceled/paused) has NO next-billed date, and passing an explicit nil
        # would NULL the stored access-until on every hourly tick (a paying account
        # mid-cancel silently loses its "access until"). Status always updates.
        attrs =
          case Billing.extract_next_billed_at(subscription_data) do
            nil -> %{status: subscription_data["status"]}
            period_end -> %{status: subscription_data["status"], current_period_end: period_end}
          end

        Billing.upsert_subscription(account_id, attrs)

      {:error, reason} ->
        # Don't fail the whole sweep — a single bad subscription must
        # not block the rest — but surface every failure to Logger so
        # a permanent Paddle credential revocation (or one tenant whose
        # subscription was deleted out from under us) doesn't go
        # invisible. Sentry's Logger backend picks this up automatically.
        Logger.warning("billing_sync.retrieve_failed",
          paddle_subscription_id: paddle_subscription_id,
          account_id: account_id,
          error: inspect(reason)
        )

        :ok
    end
  end
end
