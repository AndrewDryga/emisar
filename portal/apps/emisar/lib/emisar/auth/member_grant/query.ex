defmodule Emisar.Auth.MemberGrant.Query do
  use Emisar, :query
  alias Emisar.Auth.MemberGrant

  def all, do: from(grants in MemberGrant, as: :member_grants)

  def by_token_id(queryable \\ all(), token_id),
    do: where(queryable, [member_grants: g], g.user_token_id == ^token_id)

  def by_membership(queryable \\ all(), account_id, membership_id) do
    where(
      queryable,
      [member_grants: g],
      g.account_id == ^account_id and g.membership_id == ^membership_id
    )
  end

  def select_account_ids(queryable),
    do: select(queryable, [member_grants: g], g.account_id)

  def ordered_by_id(queryable), do: order_by(queryable, [member_grants: g], asc: g.id)

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")

  def with_joined_token(queryable) do
    with_named_binding(queryable, :grant_token, fn queryable, binding ->
      join(queryable, :inner, [member_grants: g], token in assoc(g, :user_token), as: ^binding)
    end)
  end

  def select_token_digests(queryable) do
    queryable
    |> with_joined_token()
    |> select([grant_token: t], t.token)
  end
end
