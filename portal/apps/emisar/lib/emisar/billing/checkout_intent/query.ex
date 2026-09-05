defmodule Emisar.Billing.CheckoutIntent.Query do
  use Emisar, :query
  alias Emisar.Billing.CheckoutIntent

  def all, do: from(intents in CheckoutIntent, as: :checkout_intents)
  def by_id(queryable \\ all(), id), do: where(queryable, [checkout_intents: i], i.id == ^id)

  def by_account_id(queryable \\ all(), id),
    do: where(queryable, [checkout_intents: i], i.account_id == ^id)

  def by_transaction_id(queryable \\ all(), id),
    do: where(queryable, [checkout_intents: i], i.transaction_id == ^id)

  def pending(queryable \\ all()),
    do: where(queryable, [checkout_intents: i], i.state not in [:subscribed, :canceled, :failed])

  def after_id(queryable, nil), do: queryable
  def after_id(queryable, id), do: where(queryable, [checkout_intents: i], i.id > ^id)
  def ordered_by_id(queryable), do: order_by(queryable, [checkout_intents: i], asc: i.id)
  def limit_to(queryable, limit), do: limit(queryable, ^limit)
  def lock_for_update(queryable), do: lock(queryable, "FOR NO KEY UPDATE")
end
