defmodule Emisar.Billing.Subscription.Changeset do
  use Emisar, :changeset
  alias Emisar.Billing.Subscription

  @fields ~w[
    account_id paddle_subscription_id paddle_price_id plan status
    quantity current_period_start current_period_end cancel_at_period_end trial_end
    paddle_updated_at
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
      # `status` deliberately stays an open `:string` (no Ecto.Enum, no
      # inclusion list): Paddle owns the value space, and a status this
      # code has never seen must still persist — a validation error here
      # would 500 the webhook and strand the account's entitlement on
      # every redelivery. `Subscription.active?/1` names the statuses we
      # actually branch on.
      subscription
      |> cast(attrs, @fields)
      |> validate_required([:account_id, :plan, :status])
      |> unique_constraint(:account_id)
    end
  end

  # True only when the stored row AND the incoming attrs both carry a Paddle
  # `updated_at` and the incoming one is strictly older. A first insert (no
  # stored timestamp) or an event without one always applies.
  defp stale_update?(%Subscription{paddle_updated_at: %DateTime{} = stored}, attrs) do
    case attrs[:paddle_updated_at] || attrs["paddle_updated_at"] do
      %DateTime{} = incoming -> DateTime.compare(incoming, stored) == :lt
      _ -> false
    end
  end

  defp stale_update?(_subscription, _attrs), do: false
end
