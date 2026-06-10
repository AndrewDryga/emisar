defmodule Emisar.Policies.Policy.Query do
  use Emisar, :query

  def all,
    do: from(policies in Emisar.Policies.Policy, as: :policies)

  def not_deleted(queryable \\ all()),
    do: where(queryable, [policies: p], is_nil(p.deleted_at))

  def by_id(queryable, id),
    do: where(queryable, [policies: p], p.id == ^id)

  def by_account_id(queryable, account_id),
    do: where(queryable, [policies: p], p.account_id == ^account_id)
end
