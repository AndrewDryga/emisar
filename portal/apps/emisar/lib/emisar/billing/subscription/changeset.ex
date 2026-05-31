defmodule Emisar.Billing.Subscription.Changeset do
  use Emisar, :changeset
  alias Emisar.Billing.Subscription

  @statuses ~w(trialing active past_due canceled unpaid incomplete incomplete_expired paused)
  @fields ~w[
    account_id paddle_subscription_id paddle_price_id plan status
    quantity current_period_start current_period_end cancel_at_period_end trial_end
  ]a

  def upsert(sub \\ %Subscription{}, attrs) do
    sub
    |> cast(attrs, @fields)
    |> validate_required([:account_id, :plan, :status])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:account_id)
  end

  def statuses, do: @statuses
end
