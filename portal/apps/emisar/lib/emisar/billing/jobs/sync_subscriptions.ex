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

  @subscriptions_per_page 100

  @impl Emisar.Jobs.Executors.GloballyUnique
  def execute(config) do
    limit = Keyword.get(config, :limit, @subscriptions_per_page)
    sweep_page(limit, nil)
  end

  defp sweep_page(limit, after_subscription_id) do
    subscriptions =
      Billing.Subscription.Query.all()
      |> after_subscription(after_subscription_id)
      |> Billing.Subscription.Query.ordered_by_id()
      |> Billing.Subscription.Query.limit_to(limit)
      |> Repo.all()

    Enum.each(subscriptions, &sync_safely/1)

    if length(subscriptions) == limit do
      sweep_page(limit, List.last(subscriptions).id)
    else
      :ok
    end
  end

  defp after_subscription(queryable, id) when is_binary(id),
    do: Billing.Subscription.Query.after_id(queryable, id)

  defp after_subscription(queryable, _id), do: queryable

  defp sync_safely(%Billing.Subscription{} = subscription) do
    sync(subscription)
  rescue
    error ->
      Logger.warning("billing_sync.crashed",
        paddle_subscription_id: subscription.paddle_subscription_id,
        account_id: subscription.account_id,
        error: inspect(error.__struct__)
      )

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
