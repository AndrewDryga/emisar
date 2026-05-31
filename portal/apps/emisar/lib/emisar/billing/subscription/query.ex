defmodule Emisar.Billing.Subscription.Query do
  use Emisar, :query

  def all,
    do: from(subscriptions in Emisar.Billing.Subscription, as: :subscriptions)

  def by_id(q, id),
    do: where(q, [subscriptions: s], s.id == ^id)

  def by_account_id(q, account_id),
    do: where(q, [subscriptions: s], s.account_id == ^account_id)

  def by_paddle_subscription_id(q, sid),
    do: where(q, [subscriptions: s], s.paddle_subscription_id == ^sid)

  def by_status(q, status),
    do: where(q, [subscriptions: s], s.status == ^status)

  def active(q \\ all()),
    do: where(q, [subscriptions: s], s.status in ["trialing", "active"])
end
