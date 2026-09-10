defmodule Emisar.SSO.DirectoryGroupMember.Query do
  use Emisar, :query
  alias Emisar.SSO.DirectoryGroupMember

  def all,
    do: from(group_members in DirectoryGroupMember, as: :group_members)

  def not_deleted(queryable \\ all()),
    do: where(queryable, [group_members: g], is_nil(g.deleted_at))

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

  # Roster relationships, not authorization grants: suspended/deactivated people
  # remain members. Every join fences both the workspace and the connection.
  def with_directory_roster(queryable) do
    queryable
    |> join(:inner, [group_members: link], identity in Emisar.SSO.UserIdentity,
      as: :directory_identity,
      on:
        identity.id == link.user_identity_id and identity.account_id == link.account_id and
          identity.provider_id == link.provider_id and is_nil(identity.deleted_at) and
          is_nil(identity.scim_deleted_at)
    )
    |> join(:inner, [group_members: link], group in Emisar.SSO.DirectoryGroup,
      as: :directory_group,
      on:
        group.id == link.directory_group_id and group.account_id == link.account_id and
          group.provider_id == link.provider_id and is_nil(group.deleted_at)
    )
    |> join(:inner, [group_members: link], provider in Emisar.SSO.IdentityProvider,
      as: :directory_provider,
      on:
        provider.id == link.provider_id and provider.account_id == link.account_id and
          is_nil(provider.deleted_at)
    )
    |> join(:inner, [directory_identity: identity], member in Emisar.Accounts.Membership,
      as: :directory_member,
      on:
        member.user_id == identity.user_id and member.account_id == identity.account_id and
          is_nil(member.deleted_at)
    )
    |> join(:inner, [directory_identity: identity], user in Emisar.Users.User,
      as: :directory_user,
      on: user.id == identity.user_id and is_nil(user.deleted_at)
    )
  end

  def by_roster_user_ids(queryable, ids),
    do: where(queryable, [directory_identity: i], i.user_id in ^ids)

  def select_roster_group_ids(queryable),
    do: select(queryable, [group_members: l], l.directory_group_id)

  def select_roster_identity_ids(queryable),
    do: select(queryable, [directory_identity: i], i.id)

  def roster_group_counts(queryable) do
    queryable
    |> group_by([group_members: link], link.directory_group_id)
    |> select([group_members: link, directory_identity: identity], %{
      directory_group_id: link.directory_group_id,
      member_count: count(identity.user_id, :distinct)
    })
  end

  # Rank distinct groups across ALL of a person's provider identities. Keep the
  # outer base table so Authorizer can still add its account fence.
  def first_groups_per_user(queryable, limit) do
    distinct_groups =
      queryable
      |> distinct([directory_identity: identity, directory_group: group], [
        identity.user_id,
        group.id
      ])
      |> select(
        [
          group_members: link,
          directory_identity: identity,
          directory_group: group,
          directory_provider: provider
        ],
        %{
          link_id: link.id,
          user_id: identity.user_id,
          id: group.id,
          provider_id: group.provider_id,
          provider_name: provider.name,
          display: group.display,
          external_group_id: group.external_group_id
        }
      )

    ranked =
      from(group in subquery(distinct_groups),
        as: :group_facts,
        windows: [
          person: [partition_by: group.user_id],
          ordered: [
            partition_by: group.user_id,
            order_by: [
              asc:
                fragment(
                  "lower(coalesce(nullif(btrim(?), ''), ?, ?::text))",
                  group.display,
                  group.external_group_id,
                  group.id
                ),
              asc: group.provider_name,
              asc: group.id
            ]
          ]
        ],
        select:
          merge(group, %{position: over(row_number(), :ordered), total: over(count(), :person)})
      )

    all()
    |> join(:inner, [group_members: link], group in subquery(ranked),
      as: :group_facts,
      on: group.link_id == link.id and group.position <= ^limit
    )
    |> order_by([group_facts: group], asc: group.user_id, asc: group.position)
    |> select([group_facts: g], %{
      user_id: type(g.user_id, Ecto.UUID),
      id: type(g.id, Ecto.UUID),
      provider_id: type(g.provider_id, Ecto.UUID),
      provider_name: g.provider_name,
      display: g.display,
      external_group_id: g.external_group_id,
      total: g.total
    })
  end

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
