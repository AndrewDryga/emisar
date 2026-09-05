defmodule Emisar.Billing.SubscriptionRetirement.Query do
  use Emisar, :query
  alias Emisar.Billing.SubscriptionRetirement

  def all, do: from(retirements in SubscriptionRetirement, as: :subscription_retirements)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [subscription_retirements: r], r.id == ^id)

  def by_account_id(queryable \\ all(), id),
    do: where(queryable, [subscription_retirements: r], r.account_id == ^id)

  def by_subscription_id(queryable \\ all(), id),
    do: where(queryable, [subscription_retirements: r], r.subscription_id == ^id)

  def pending(queryable \\ all()),
    do: where(queryable, [subscription_retirements: r], r.state == :pending)

  def after_id(queryable, nil), do: queryable
  def after_id(queryable, id), do: where(queryable, [subscription_retirements: r], r.id > ^id)
  def ordered_by_id(queryable), do: order_by(queryable, [subscription_retirements: r], asc: r.id)
  def limit_to(queryable, limit), do: limit(queryable, ^limit)
  def lock_for_update(queryable), do: lock(queryable, "FOR NO KEY UPDATE")
end
