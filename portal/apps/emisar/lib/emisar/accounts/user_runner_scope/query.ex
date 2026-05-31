defmodule Emisar.Accounts.UserRunnerScope.Query do
  use Emisar, :query

  def all,
    do: from(scopes in Emisar.Accounts.UserRunnerScope, as: :scopes)

  def by_membership_id(q \\ all(), membership_id),
    do: where(q, [scopes: s], s.membership_id == ^membership_id)

  def by_membership_ids(q \\ all(), ids),
    do: where(q, [scopes: s], s.membership_id in ^ids)

  def ordered(q \\ all()),
    do: order_by(q, [scopes: s], asc: s.scope_type, asc: s.scope_value)
end
