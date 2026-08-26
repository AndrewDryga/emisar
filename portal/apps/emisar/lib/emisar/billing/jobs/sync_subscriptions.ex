defmodule Emisar.Billing.Jobs.SyncSubscriptions do
  @moduledoc """
  Periodic reconciliation against Paddle subscriptions.
  """
  use Emisar.Jobs.Job,
    otp_app: :emisar,
    every: :timer.hours(1),
    initial_delay: :timer.minutes(2),
    executor: Emisar.Jobs.Executors.GloballyUnique

  alias Emisar.{Billing, Repo}
  require Logger

  @subscriptions_per_page 100

  @impl Emisar.Jobs.Executors.GloballyUnique
  def execute(config) do
    limit = Keyword.get(config, :limit, @subscriptions_per_page)
    :ok = sweep_page(limit, nil)
    discover_page(limit, nil)
  end

  defp sweep_page(limit, after_subscription_id) do
    subscriptions =
      Billing.Subscription.Query.all()
      # A closed account's subscription is cancelled at Paddle by close_account/3;
      # re-syncing it here would pull the plan straight back.
      |> Billing.Subscription.Query.with_live_account()
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

  defp sync(
         %Billing.Subscription{
           paddle_subscription_id: paddle_subscription_id,
           account_id: account_id
         } = subscription
       ) do
    case Billing.PaddleClient.retrieve_subscription(paddle_subscription_id) do
      {:ok, subscription_data} ->
        case Billing.reconcile_subscription_data(subscription_data,
               expected_subscription: subscription
             ) do
          {:ok, synced_subscription} ->
            sync_runner_quantity_safely(synced_subscription)

          :ok ->
            Logger.warning("billing_sync.subscription_unmatched",
              paddle_subscription_id: paddle_subscription_id,
              account_id: account_id
            )

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

  defp sync_runner_quantity_safely(%Billing.Subscription{} = subscription) do
    case Billing.reconcile_runner_quantity(subscription.id) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning("billing_sync.runner_quantity_failed",
          paddle_subscription_id: subscription.paddle_subscription_id,
          account_id: subscription.account_id,
          error: inspect(Billing.redacted_paddle_error(reason))
        )
    end
  end

  # The local-row sweep repairs missed updates. This provider-side discovery
  # pass repairs the other half: a missed subscription.created event left no
  # local row to retrieve, so list current subscriptions and resolve each one by
  # its mirrored Paddle customer id.
  defp discover_page(limit, after_cursor) do
    case Billing.PaddleClient.list_subscriptions(limit: limit, after: after_cursor) do
      {:ok, %{subscriptions: subscriptions, next_after: next_after}}
      when is_list(subscriptions) ->
        Enum.each(subscriptions, &reconcile_discovered_safely/1)

        case next_after do
          nil ->
            :ok

          next_after when is_binary(next_after) and next_after != after_cursor ->
            discover_page(limit, next_after)

          _repeated_or_malformed ->
            log_discovery_failure(:non_advancing_cursor)
        end

      {:error, reason} ->
        log_discovery_failure(reason)
    end
  end

  defp log_discovery_failure(reason) do
    Logger.warning("billing_sync.discovery_failed",
      error: inspect(Billing.redacted_paddle_error(reason))
    )

    :ok
  end

  defp reconcile_discovered_safely(subscription_data) do
    paddle_subscription_id = discovered_subscription_id(subscription_data)

    case Billing.reconcile_discovered_subscription_data(subscription_data) do
      {:ok, _subscription} ->
        :ok

      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("billing_sync.discovery_upsert_failed",
          paddle_subscription_id: paddle_subscription_id,
          error: inspect(Billing.redacted_paddle_error(reason))
        )
    end
  rescue
    error ->
      Logger.warning("billing_sync.discovery_crashed",
        paddle_subscription_id: discovered_subscription_id(subscription_data),
        error: inspect(error.__struct__)
      )

      :ok
  end

  defp discovered_subscription_id(%{"id" => id}) when is_binary(id), do: id
  defp discovered_subscription_id(_subscription_data), do: "unknown"
end
