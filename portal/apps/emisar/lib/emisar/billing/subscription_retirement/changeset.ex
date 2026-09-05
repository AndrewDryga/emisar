defmodule Emisar.Billing.SubscriptionRetirement.Changeset do
  use Emisar, :changeset
  alias Emisar.Billing.SubscriptionRetirement

  @fields ~w[account_id customer_id transaction_id subscription_id canonical_subscription_id reason]a

  def enqueue(attrs) do
    %SubscriptionRetirement{}
    |> cast(attrs, @fields)
    |> put_change(:state, :pending)
    |> validate_required([:account_id, :customer_id, :transaction_id, :subscription_id, :reason])
    |> unique_constraint(:subscription_id)
    |> check_constraint(:state, name: :billing_subscription_retirements_shape)
  end

  def confirm(%SubscriptionRetirement{} = retirement) do
    retirement
    |> change(state: :confirmed, confirmed_at: DateTime.utc_now(), failure_category: nil)
    |> check_constraint(:state, name: :billing_subscription_retirements_shape)
  end

  def record_failure(%SubscriptionRetirement{state: :pending} = retirement, category),
    do: change(retirement, failure_category: category)

  def record_failure(%SubscriptionRetirement{} = retirement, _category), do: change(retirement)
end
