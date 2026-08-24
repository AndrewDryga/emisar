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

  def by_directory_group_id(queryable \\ all(), directory_group_id),
    do: where(queryable, [group_members: g], g.directory_group_id == ^directory_group_id)

  def by_directory_group_ids(queryable \\ all(), directory_group_ids),
    do: where(queryable, [group_members: g], g.directory_group_id in ^directory_group_ids)

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

  def with_joined_scim_identity(queryable \\ all()) do
    identities =
      Emisar.SSO.UserIdentity.Query.not_deleted()
      |> Emisar.SSO.UserIdentity.Query.scim_not_deleted()

    with_named_binding(queryable, :identities, fn queryable, binding ->
      join(queryable, :inner, [group_members: g], identity in ^identities,
        on: identity.id == g.user_identity_id,
        as: ^binding
      )
    end)
  end

  def with_joined_retired_scim_identity(queryable \\ all()) do
    identities =
      Emisar.SSO.UserIdentity.Query.not_deleted()
      |> Emisar.SSO.UserIdentity.Query.scim_deleted()

    with_named_binding(queryable, :identities, fn queryable, binding ->
      join(queryable, :inner, [group_members: g], identity in ^identities,
        on: identity.id == g.user_identity_id,
        as: ^binding
      )
    end)
  end

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
    |> with_joined_scim_identity()
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

  def by_external_group_ids(queryable \\ all(), external_group_ids),
    do: where(queryable, [group_members: g], g.external_group_id in ^external_group_ids)

  # Every membership link a provider has, as `{directory_group_id,
  # user_identity_id}` pairs — SCIM Group members reference the server-issued
  # User resource id. The live SCIM identity join makes a retired wire resource
  # leave the rendered group while its shared OIDC/identity row stays reserved.
  def select_member_ids(queryable \\ all(), provider_id) do
    queryable
    |> where([group_members: g], g.provider_id == ^provider_id)
    |> with_joined_scim_identity()
    |> order_by([group_members: g, identities: i],
      asc: g.directory_group_id,
      asc: i.id
    )
    |> select([group_members: g, identities: i], {g.directory_group_id, i.id})
  end
end
