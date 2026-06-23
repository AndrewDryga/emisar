defmodule Emisar.SSO.DirectoryGroupMember.Query do
  use Emisar, :query
  alias Emisar.SSO.DirectoryGroupMember

  def all,
    do: from(group_members in DirectoryGroupMember, as: :group_members)

  def not_deleted(queryable \\ all()),
    do: where(queryable, [group_members: g], is_nil(g.deleted_at))

  def by_provider_and_group(queryable, provider_id, external_group_id),
    do:
      where(
        queryable,
        [group_members: g],
        g.provider_id == ^provider_id and g.external_group_id == ^external_group_id
      )

  def by_user_identity_id(queryable, user_identity_id),
    do: where(queryable, [group_members: g], g.user_identity_id == ^user_identity_id)

  def by_user_identity_ids(queryable, user_identity_ids),
    do: where(queryable, [group_members: g], g.user_identity_id in ^user_identity_ids)

  def by_ids(queryable, ids),
    do: where(queryable, [group_members: g], g.id in ^ids)

  # The distinct external group ids a provider has seen via SCIM — the source
  # for the mapping picker (map-after-first-sync), so an admin keys a role
  # mapping on a group the IdP has actually synced rather than a guessed id.
  def distinct_group_ids_for_provider(queryable \\ all(), provider_id) do
    queryable
    |> where([group_members: g], g.provider_id == ^provider_id)
    |> distinct([group_members: g], g.external_group_id)
    |> order_by([group_members: g], asc: g.external_group_id)
    |> select([group_members: g], g.external_group_id)
  end
end
