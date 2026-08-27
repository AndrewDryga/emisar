defmodule Emisar.Billing.Subscription.Query do
  use Emisar, :query

  def all,
    do: from(subscriptions in Emisar.Billing.Subscription, as: :subscriptions)

  def none(queryable), do: where(queryable, false)

  def by_account_id(queryable, account_id),
    do: where(queryable, [subscriptions: s], s.account_id == ^account_id)

  def by_id(queryable, id),
    do: where(queryable, [subscriptions: s], s.id == ^id)

  def by_paddle_subscription_id(queryable, paddle_subscription_id),
    do: where(queryable, [subscriptions: s], s.paddle_subscription_id == ^paddle_subscription_id)

  def after_id(queryable, id),
    do: where(queryable, [subscriptions: s], s.id > ^id)

  def ordered_by_id(queryable),
    do: order_by(queryable, [subscriptions: s], asc: s.id)

  def limit_to(queryable, n) when is_integer(n) and n > 0,
    do: limit(queryable, ^n)

  def paddle_managed(queryable),
    do: where(queryable, [subscriptions: s], not is_nil(s.paddle_subscription_id))

  def runner_quantity_sync_requested(queryable),
    do: where(queryable, [subscriptions: s], not is_nil(s.runner_quantity_sync_requested_at))

  def runner_quantity_sync_not_requested(queryable),
    do: where(queryable, [subscriptions: s], is_nil(s.runner_quantity_sync_requested_at))

  def quantity_syncable(queryable),
    do: where(queryable, [subscriptions: s], s.status != "canceled")

  @doc """
  Internal — subscriptions whose account is still live. The hourly reconcile
  starts from `all/0`, so without this it kept pulling a closed account's plan
  back from Paddle after `close_account/3` cancelled it.
  """
  def with_live_account(queryable \\ all()) do
    join(
      queryable,
      :inner,
      [subscriptions: s],
      account in ^Emisar.Accounts.Account.Query.not_deleted(),
      on: s.account_id == account.id,
      as: :account
    )
  end

  def lock_for_update(queryable), do: lock(queryable, "FOR NO KEY UPDATE")
end
