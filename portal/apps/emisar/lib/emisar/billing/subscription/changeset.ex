defmodule Emisar.Billing.Subscription.Changeset do
  use Emisar, :changeset
  alias Emisar.Billing.Subscription

  @fields ~w[
    account_id paddle_subscription_id paddle_price_id plan status collection_mode billing_interval
    unit_price_amount currency_code billing_frequency entitlements quantity
    current_period_start current_period_end cancel_at_period_end scheduled_change_action
    scheduled_change_effective_at trial_end paddle_updated_at paddle_event_occurred_at
    runner_quantity_sync_requested_at
  ]a

  @doc """
  A support/seed write that is NOT a vendor mirror update.

  `upsert/2` drops any event it cannot prove is newer than Paddle's stored
  `updated_at`, which is right for a webhook and wrong for a human: once an
  account had ever been mirrored, `mix emisar.set_plan` and the seeds were
  silently dropped — Ecto returned the unchanged row, so the task printed
  success and nothing had happened. A manual write is authoritative by
  definition, so it skips the guard and clears the vendor timestamp, which
  hands the mirror back to the next real webhook.
  """
  def manual(subscription \\ %Subscription{}, attrs) do
    subscription
    |> cast(attrs, @fields)
    |> put_change(:paddle_updated_at, nil)
    |> put_change(:paddle_event_occurred_at, nil)
    |> validate_required([:account_id, :plan, :status])
    |> validate_number(:unit_price_amount, greater_than_or_equal_to: 0)
    |> validate_number(:billing_frequency, greater_than: 0)
    |> unique_constraint(:account_id)
  end

  def upsert(subscription \\ %Subscription{}, attrs) do
    if stale_update?(subscription, attrs) do
      # Out-of-order Paddle delivery: a late event whose `updated_at` predates
      # the stored row would clobber fresher state (e.g. a `canceled` delivered
      # after the `active` that superseded it). Drop it — an empty changeset is a
      # no-op update that returns the row unchanged. Same-or-newer applies; exact
      # redeliveries are already caught by the `paddle_processed_events` dedup.
      change(subscription)
    else
      # `status` stays open: Paddle owns most values and support uses the
      # local `complimentary` value. An unseen vendor status must still persist
      # or a webhook would 500 and strand the account's entitlement.
      subscription
      |> cast(attrs, @fields)
      |> validate_required([:account_id, :plan, :status])
      |> validate_number(:unit_price_amount, greater_than_or_equal_to: 0)
      |> validate_number(:billing_frequency, greater_than: 0)
      |> unique_constraint(:account_id)
    end
  end

  # Once the mirror has Paddle's monotonic timestamp, an incoming event must
  # carry one too. A partial payload without it cannot prove it is newer, so
  # dropping it prevents an old delivery from rewinding the mirror. Legacy rows
  # without a stored timestamp still accept the next event and establish the
  # guard when Paddle supplies `updated_at`.
  defp stale_update?(%Subscription{} = subscription, attrs) do
    incoming_event = attrs[:paddle_event_occurred_at]
    incoming_object = attrs[:paddle_updated_at]

    stored_latest =
      latest_timestamp(subscription.paddle_event_occurred_at, subscription.paddle_updated_at)

    event_stale? =
      if is_struct(incoming_event, DateTime),
        do: older?(incoming_event, subscription.paddle_event_occurred_at),
        else:
          Map.has_key?(attrs, :paddle_event_occurred_at) and is_struct(stored_latest, DateTime)

    object_stale? =
      cond do
        is_struct(incoming_object, DateTime) ->
          older?(incoming_object, subscription.paddle_updated_at)

        Map.has_key?(attrs, :paddle_updated_at) and
            is_struct(subscription.paddle_updated_at, DateTime) ->
          true

        true ->
          false
      end

    missing_order? =
      not is_struct(incoming_event, DateTime) and not is_struct(incoming_object, DateTime) and
        is_struct(stored_latest, DateTime)

    event_stale? or object_stale? or missing_order?
  end

  defp latest_timestamp(nil, nil), do: nil
  defp latest_timestamp(%DateTime{} = timestamp, nil), do: timestamp
  defp latest_timestamp(nil, %DateTime{} = timestamp), do: timestamp

  defp latest_timestamp(%DateTime{} = left, %DateTime{} = right) do
    if DateTime.compare(left, right) == :lt, do: right, else: left
  end

  defp older?(_incoming, nil), do: false
  defp older?(incoming, stored), do: DateTime.compare(incoming, stored) == :lt
end
