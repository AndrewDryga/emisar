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

  def by_ids(queryable, ids),
    do: where(queryable, [group_members: g], g.id in ^ids)
end
