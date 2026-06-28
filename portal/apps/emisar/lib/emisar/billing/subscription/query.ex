defmodule Emisar.Billing.Subscription.Query do
  use Emisar, :query

  def all,
    do: from(subscriptions in Emisar.Billing.Subscription, as: :subscriptions)

  def by_id(queryable, id),
    do: where(queryable, [subscriptions: s], s.id == ^id)

  def by_account_id(queryable, account_id),
    do: where(queryable, [subscriptions: s], s.account_id == ^account_id)

  def by_paddle_subscription_id(queryable, paddle_subscription_id),
    do: where(queryable, [subscriptions: s], s.paddle_subscription_id == ^paddle_subscription_id)
end
