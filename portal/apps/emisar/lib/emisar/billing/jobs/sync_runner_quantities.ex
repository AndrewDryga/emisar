defmodule Emisar.Billing.Jobs.SyncRunnerQuantities do
  @moduledoc """
  Coalesces billable-runner transitions into absolute Paddle quantities.

  The durable subscription marker is the outbox. The hourly subscription
  sweep also calls the same reconciler so a missed marker still converges.
  """
  use Emisar.Jobs.Job,
    otp_app: :emisar,
    every: :timer.minutes(20),
    initial_delay: :timer.minutes(4),
    executor: Emisar.Jobs.Executors.GloballyUnique

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
      |> Billing.Subscription.Query.with_live_account()
      |> Billing.Subscription.Query.paddle_managed()
      |> Billing.Subscription.Query.runner_quantity_sync_requested()
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
    case Billing.reconcile_runner_quantity(subscription.id) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning("billing_runner_quantity_sync.failed",
          paddle_subscription_id: subscription.paddle_subscription_id,
          account_id: subscription.account_id,
          error: inspect(Billing.redacted_paddle_error(reason))
        )
    end
  rescue
    error ->
      Logger.warning("billing_runner_quantity_sync.crashed",
        paddle_subscription_id: subscription.paddle_subscription_id,
        account_id: subscription.account_id,
        error: inspect(error.__struct__)
      )

      :ok
  end
end
