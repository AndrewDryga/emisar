defmodule Emisar.Accounts.MembershipRunnerScope.Query do
  use Emisar, :query

  def all do
    from(scopes in Emisar.Accounts.MembershipRunnerScope, as: :scopes)
  end

  def by_membership_id(queryable \\ all(), membership_id),
    do: where(queryable, [scopes: s], s.membership_id == ^membership_id)

  def by_membership_ids(queryable \\ all(), ids),
    do: where(queryable, [scopes: s], s.membership_id in ^ids)

  def ordered_by_type_and_value(queryable \\ all()),
    do: order_by(queryable, [scopes: s], asc: s.scope_type, asc: s.scope_value)
end
