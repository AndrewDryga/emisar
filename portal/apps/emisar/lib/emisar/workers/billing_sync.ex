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
        # Only set current_period_end / paddle_updated_at when Paddle reports
        # them: a non-renewing sub (canceled/paused) has NO next-billed date, and
        # passing an explicit nil would NULL the stored value every hourly tick (a
        # paying account mid-cancel silently loses its "access until"). Status
        # always updates; paddle_updated_at lets the upsert drop an out-of-order
        # write (the live retrieve is always freshest, so the sweep itself never
        # loses — the guard only blocks a stale webhook).
        attrs =
          %{status: subscription_data["status"]}
          |> maybe_put(:current_period_end, Billing.extract_next_billed_at(subscription_data))
          |> maybe_put(:paddle_updated_at, Billing.extract_paddle_updated_at(subscription_data))

        case Billing.upsert_subscription(account_id, attrs) do
          {:ok, _subscription} ->
            :ok

          {:error, reason} ->
            # An upsert failure (changeset/constraint) must not vanish — log it
            # like the retrieve failure so a bad payload surfaces to Sentry.
            Logger.warning("billing_sync.upsert_failed",
              paddle_subscription_id: paddle_subscription_id,
              account_id: account_id,
              error: inspect(reason)
            )
        end

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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
