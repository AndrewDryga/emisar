defmodule Emisar.Billing.Jobs.SyncSubscriptions do
  @moduledoc """
  Periodic reconciliation against Paddle subscriptions.
  """
  use Emisar.Jobs.Job,
    otp_app: :emisar,
    every: :timer.hours(1),
    initial_delay: :timer.minutes(2),
    executor: Emisar.Jobs.Executors.GloballyUnique

  import Emisar.Maps, only: [put_present: 3]
  alias Emisar.{Billing, Repo}
  require Logger

  @impl Emisar.Jobs.Executors.GloballyUnique
  def execute(_config) do
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
        plan = Billing.Entitlements.plan_slug(subscription_data)
        entitlements = Billing.Entitlements.from_paddle_subscription(subscription_data)

        attrs =
          %{status: subscription_data["status"]}
          |> Map.merge(Billing.subscription_item_attrs(subscription_data))
          |> put_present(:plan, plan)
          |> put_present(:entitlements, entitlements)
          |> put_present(:current_period_end, Billing.extract_next_billed_at(subscription_data))
          |> put_present(:paddle_updated_at, Billing.extract_paddle_updated_at(subscription_data))

        case Billing.upsert_subscription(account_id, attrs) do
          {:ok, _subscription} ->
            :ok

          {:error, reason} ->
            Logger.warning("billing_sync.upsert_failed",
              paddle_subscription_id: paddle_subscription_id,
              account_id: account_id,
              error: inspect(Billing.redacted_paddle_error(reason))
            )
        end

      {:error, reason} ->
        Logger.warning("billing_sync.retrieve_failed",
          paddle_subscription_id: paddle_subscription_id,
          account_id: account_id,
          error: inspect(Billing.redacted_paddle_error(reason))
        )

        :ok
    end
  end
end
