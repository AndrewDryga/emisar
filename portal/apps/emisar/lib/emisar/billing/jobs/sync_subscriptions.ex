defmodule Emisar.Billing.Jobs.SyncSubscriptions do
  @moduledoc """
  Periodic reconciliation against Paddle subscriptions.
  """
  use Emisar.Jobs.Job,
    otp_app: :emisar,
    every: :timer.hours(1),
    initial_delay: :timer.minutes(2)

  alias Emisar.{Billing, Jobs, Repo}
  require Logger

  @subscriptions_per_page 100
  @max_discovery_pages 100

  @impl Emisar.Jobs.Executors.GloballyUnique
  def execute(config) do
    limit = Keyword.get(config, :limit, @subscriptions_per_page)
    :ok = Jobs.Sweep.each_row(limit, &list_checkout_intents/2, &Billing.Checkouts.recover/1)
    :ok = Jobs.Sweep.each_row(limit, &list_subscriptions/2, &sync/1)
    :ok = discover_safely(limit)

    Jobs.Sweep.each_row(
      limit,
      &list_subscription_retirements/2,
      &Billing.SubscriptionRetirements.recover/1
    )
  end

  defp after_subscription(queryable, id) when is_binary(id),
    do: Billing.Subscription.Query.after_id(queryable, id)

  defp after_subscription(queryable, _id), do: queryable

  # A raising subscription is isolated by `Jobs.Sweep`, which logs
  # `sweep.row_failed` and carries on; the discovery pass below is not a sweep
  # loop and keeps its own rescue.
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
          {:ok, %Billing.Subscription{} = synced_subscription} ->
            sync_runner_quantity_safely(synced_subscription)

          {:ok, _retirement} ->
            :ok

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
  defp discover_safely(limit) do
    discover_page(limit, nil, MapSet.new(), 0)
  rescue
    error -> log_discovery_failure(error.__struct__)
  end

  defp discover_page(_limit, _after_cursor, _seen, @max_discovery_pages),
    do: log_discovery_failure(:discovery_page_limit)

  defp discover_page(limit, after_cursor, seen, page) do
    case Billing.PaddleClient.list_subscriptions(limit: limit, after: after_cursor) do
      {:ok, %{subscriptions: subscriptions, next_after: next_after}}
      when is_list(subscriptions) ->
        Enum.each(subscriptions, &reconcile_discovered_safely/1)

        case next_after do
          nil ->
            :ok

          next_after when is_binary(next_after) and next_after != after_cursor ->
            if MapSet.member?(seen, next_after) do
              log_discovery_failure(:non_advancing_cursor)
            else
              discover_page(limit, next_after, MapSet.put(seen, next_after), page + 1)
            end

          _repeated_or_malformed ->
            log_discovery_failure(:non_advancing_cursor)
        end

      {:error, reason} ->
        log_discovery_failure(reason)

      _malformed ->
        log_discovery_failure(:malformed_subscription_page)
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

  defp list_subscriptions(limit, cursor) do
    Billing.Subscription.Query.all()
    # A closed account's subscription is cancelled at Paddle by close_account/3;
    # re-syncing it here would pull the plan straight back.
    |> Billing.Subscription.Query.with_live_account()
    |> after_subscription(cursor)
    |> Billing.Subscription.Query.ordered_by_id()
    |> Billing.Subscription.Query.limit_to(limit)
    |> Repo.all()
  end

  defp list_checkout_intents(limit, cursor) do
    Billing.CheckoutIntent.Query.pending()
    |> Billing.CheckoutIntent.Query.after_id(cursor)
    |> Billing.CheckoutIntent.Query.ordered_by_id()
    |> Billing.CheckoutIntent.Query.limit_to(limit)
    |> Repo.all()
  end

  defp list_subscription_retirements(limit, cursor) do
    Billing.SubscriptionRetirement.Query.pending()
    |> Billing.SubscriptionRetirement.Query.after_id(cursor)
    |> Billing.SubscriptionRetirement.Query.ordered_by_id()
    |> Billing.SubscriptionRetirement.Query.limit_to(limit)
    |> Repo.all()
  end
end
