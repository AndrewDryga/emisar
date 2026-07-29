defmodule Emisar.SSO.DirectoryGroupMember.Query do
  use Emisar, :query
  alias Emisar.SSO.DirectoryGroupMember

  def all,
    do: from(group_members in DirectoryGroupMember, as: :group_members)

  def not_deleted(queryable \\ all()),
    do: where(queryable, [group_members: g], is_nil(g.deleted_at))

  def by_provider_and_group(queryable, provider_id, external_group_id) do
    where(
      queryable,
      [group_members: g],
      g.provider_id == ^provider_id and g.external_group_id == ^external_group_id
    )
  end

  def by_provider_id(queryable \\ all(), provider_id),
    do: where(queryable, [group_members: g], g.provider_id == ^provider_id)

  def by_user_identity_id(queryable, user_identity_id),
    do: where(queryable, [group_members: g], g.user_identity_id == ^user_identity_id)

  def by_user_identity_ids(queryable, user_identity_ids),
    do: where(queryable, [group_members: g], g.user_identity_id in ^user_identity_ids)

  def by_ids(queryable, ids),
    do: where(queryable, [group_members: g], g.id in ^ids)

  def by_account_id(queryable \\ all(), account_id),
    do: where(queryable, [group_members: g], g.account_id == ^account_id)

  # Distinct external groups a directory has actually pushed via SCIM, tallied per
  # provider — the overview health line's "N groups synced". Counts what SYNCED (a
  # directory can push more groups than the admin has mapped), not the group→role
  # mappings; `{provider_id, count}` tuples, so a caller `Map.new`s them.
  def count_distinct_groups_by_provider(queryable \\ all()) do
    queryable
    |> group_by([group_members: g], g.provider_id)
    |> select([group_members: g], {g.provider_id, count(g.external_group_id, :distinct)})
  end

  # Each external group a provider has synced via SCIM with its distinct member
  # count — powers the synced-groups readout, and (projected to ids) the
  # map-after-first-sync picker, so an admin keys a role mapping on a group the
  # IdP has actually synced rather than a guessed id.
  def group_counts_for_provider(queryable \\ all(), provider_id) do
    queryable
    |> where([group_members: g], g.provider_id == ^provider_id)
    |> group_by([group_members: g], g.external_group_id)
    |> order_by([group_members: g], asc: g.external_group_id)
    |> select([group_members: g], %{
      external_group_id: g.external_group_id,
      member_count: count(g.user_identity_id, :distinct)
    })
  end

  def by_external_group_id(queryable \\ all(), external_group_id),
    do: where(queryable, [group_members: g], g.external_group_id == ^external_group_id)

  # The display each synced group was last pushed under, as {external_group_id,
  # display} pairs for a caller to `Map.new`. Aggregated because the display
  # lives on every member row: a PATCH `add` op carries no displayName, so its
  # row is inserted blank, and `max/1` (which ignores NULLs) still resolves the
  # group's name from the siblings a PUT stamped.
  def select_displays_for_provider(queryable \\ all(), provider_id) do
    queryable
    |> where([group_members: g], g.provider_id == ^provider_id)
    |> where([group_members: g], not is_nil(g.external_group_display))
    |> group_by([group_members: g], g.external_group_id)
    |> select([group_members: g], {g.external_group_id, max(g.external_group_display)})
  end

  # Every membership link a provider has, as {external_group_id, member externalId}
  # pairs — what a SCIM `GET /Groups` must echo back as each group's `members`.
  # Joins the identity (its `scim_external_id` is the id the IdP knows a member
  # by) scoped to `not_deleted/0`, so a soft-deleted identity leaves the group.
  def select_member_external_ids(queryable \\ all(), provider_id) do
    queryable
    |> where([group_members: g], g.provider_id == ^provider_id)
    |> join(:inner, [group_members: g], i in ^Emisar.SSO.UserIdentity.Query.not_deleted(),
      on: i.id == g.user_identity_id,
      as: :identities
    )
    |> where([identities: i], not is_nil(i.scim_external_id))
    |> order_by([group_members: g, identities: i],
      asc: g.external_group_id,
      asc: i.scim_external_id
    )
    |> select([group_members: g, identities: i], {g.external_group_id, i.scim_external_id})
  end
end
