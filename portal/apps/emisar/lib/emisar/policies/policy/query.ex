defmodule Emisar.Policies.Policy.Query do
  use Emisar, :query

  def all,
    do: from(policies in Emisar.Policies.Policy, as: :policies)

  def not_deleted(q \\ all()),
    do: where(q, [policies: p], is_nil(p.deleted_at))

  def by_id(q, id),
    do: where(q, [policies: p], p.id == ^id)

  def by_account_id(q, account_id),
    do: where(q, [policies: p], p.account_id == ^account_id)
end
