defmodule Emisar.Billing.Subscription.Query do
  use Emisar, :query

  def all,
    do: from(subscriptions in Emisar.Billing.Subscription, as: :subscriptions)

  def none(queryable), do: where(queryable, false)

  def by_account_id(queryable, account_id),
    do: where(queryable, [subscriptions: s], s.account_id == ^account_id)

  def by_paddle_subscription_id(queryable, paddle_subscription_id),
    do: where(queryable, [subscriptions: s], s.paddle_subscription_id == ^paddle_subscription_id)

  def after_id(queryable, id),
    do: where(queryable, [subscriptions: s], s.id > ^id)

  def ordered_by_id(queryable),
    do: order_by(queryable, [subscriptions: s], asc: s.id)

  def limit_to(queryable, n) when is_integer(n) and n > 0,
    do: limit(queryable, ^n)

  def complimentary(queryable \\ all()) do
    where(
      queryable,
      [subscriptions: s],
      s.status == "complimentary" and is_nil(s.paddle_subscription_id)
    )
  end

  def lock_for_update(queryable), do: lock(queryable, "FOR NO KEY UPDATE")
end
