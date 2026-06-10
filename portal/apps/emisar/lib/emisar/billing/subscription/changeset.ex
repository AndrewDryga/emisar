defmodule Emisar.Billing.Subscription.Changeset do
  use Emisar, :changeset
  alias Emisar.Billing.Subscription

  @fields ~w[
    account_id paddle_subscription_id paddle_price_id plan status
    quantity current_period_start current_period_end cancel_at_period_end trial_end
  ]a

  def upsert(subscription \\ %Subscription{}, attrs) do
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
