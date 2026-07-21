defmodule Emisar.Billing.Subscription.Changeset do
  use Emisar, :changeset
  alias Emisar.Billing.Subscription

  @fields ~w[
    account_id paddle_subscription_id paddle_price_id plan status billing_interval
    unit_price_amount currency_code billing_frequency entitlements quantity
    current_period_start current_period_end cancel_at_period_end trial_end paddle_updated_at
  ]a

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
  defp stale_update?(%Subscription{paddle_updated_at: %DateTime{} = stored}, attrs) do
    case attrs[:paddle_updated_at] || attrs["paddle_updated_at"] do
      %DateTime{} = incoming -> DateTime.compare(incoming, stored) == :lt
      _ -> true
    end
  end

  defp stale_update?(_subscription, _attrs), do: false
end
