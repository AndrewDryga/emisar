defmodule Emisar.SSO.DirectoryGroup.Query do
  use Emisar, :query
  alias Emisar.Repo.{Filter, Like}
  alias Emisar.SSO.DirectoryGroup
  alias Emisar.SSO.{GroupRoleMapping, GroupRunnerAccessMapping}

  def all, do: from(groups in DirectoryGroup, as: :groups)

  def not_deleted(queryable \\ all()),
    do: where(queryable, [groups: g], is_nil(g.deleted_at))

  # Keep saved mappings manageable after a group is retired by SCIM or disable.
  def active_or_mapped(queryable \\ all()) do
    queryable
    |> join(:left, [groups: g], mapping in GroupRoleMapping,
      as: :role_mapping,
      on:
        mapping.directory_group_id == g.id and mapping.provider_id == g.provider_id and
          mapping.account_id == g.account_id and is_nil(mapping.deleted_at)
    )
    |> join(:left, [groups: g], mapping in GroupRunnerAccessMapping,
      as: :access_mapping,
      on:
        mapping.directory_group_id == g.id and mapping.provider_id == g.provider_id and
          mapping.account_id == g.account_id and is_nil(mapping.deleted_at)
    )
    |> where(
      [groups: g, role_mapping: role, access_mapping: access],
      is_nil(g.deleted_at) or not is_nil(role.id) or not is_nil(access.id)
    )
  end

  def none(queryable), do: where(queryable, false)

  def by_account_id(queryable \\ all(), account_id),
    do: where(queryable, [groups: g], g.account_id == ^account_id)

  def by_provider_id(queryable \\ all(), provider_id),
    do: where(queryable, [groups: g], g.provider_id == ^provider_id)

  def by_id(queryable, id),
    do: where(queryable, [groups: g], g.id == ^id)

  def by_external_group_id(queryable, external_group_id),
    do: where(queryable, [groups: g], g.external_group_id == ^external_group_id)

  def for_roster_user(queryable, user_id, account_id) do
    group_ids =
      Emisar.SSO.DirectoryGroupMember.Query.not_deleted()
      |> Emisar.SSO.DirectoryGroupMember.Query.by_account_id(account_id)
      |> Emisar.SSO.DirectoryGroupMember.Query.with_directory_roster()
      |> Emisar.SSO.DirectoryGroupMember.Query.by_roster_user_ids([user_id])
      |> Emisar.SSO.DirectoryGroupMember.Query.select_roster_group_ids()

    where(queryable, [groups: g], g.id in subquery(group_ids))
  end

  def with_live_provider(queryable) do
    join(queryable, :inner, [groups: group], provider in Emisar.SSO.IdentityProvider,
      as: :directory_provider,
      on:
        provider.id == group.provider_id and provider.account_id == group.account_id and
          is_nil(provider.deleted_at)
    )
  end

  def select_directory_labels(queryable) do
    select(queryable, [groups: g, directory_provider: p], %{
      id: g.id,
      provider_id: g.provider_id,
      provider_name: p.name,
      display: g.display,
      external_group_id: g.external_group_id,
      inserted_at: g.inserted_at
    })
  end

  # Okta omits externalId on Group POST, then remembers our returned resource id
  # and probes it as `externalId eq "<id>"` before subsequent pushes. Match only
  # that exact immutable id while the IdP-owned attribute is absent; do not
  # synthesize or persist an externalId, and never fall back to displayName.
  def by_external_group_id_or_unset_resource_id(queryable, external_group_id) do
    where(
      queryable,
      [groups: g],
      g.external_group_id == ^external_group_id or
        (is_nil(g.external_group_id) and
           fragment("?::text = ?", g.id, ^external_group_id))
    )
  end

  @doc """
  The `displayName eq` probe Entra sends before every push, matched
  case-insensitively.

  `nullif(display, '')` before the fallback because SCIM treats `displayName` as
  optional, so clearing it stores an empty string — and SQL `coalesce` counts
  `''` as a value, which left the group answering to `''` instead of the id the
  IdP addresses it by. The probe then missed, and Entra re-POSTed the group as a
  duplicate on every sync.
  """
  def by_display(queryable, display) when is_binary(display) do
    where(
      queryable,
      [groups: g],
      fragment(
        "lower(coalesce(nullif(?, ''), ?)) = lower(?)",
        g.display,
        g.external_group_id,
        ^display
      )
    )
  end

  def ordered_by_external_group_id(queryable),
    do: order_by(queryable, [groups: g], asc: g.external_group_id, asc: g.id)

  def ordered_by_display(queryable) do
    order_by(queryable, [groups: g],
      asc:
        fragment(
          "lower(coalesce(nullif(?, ''), ?, ?::text))",
          g.display,
          g.external_group_id,
          g.id
        ),
      asc: g.id
    )
  end

  @doc """
  The picker's bounded search: a case-insensitive substring over the display
  name and the directory's own external id, ordered and capped here so the
  helper's name is the whole contract. A blank term is the unfiltered head of
  the same order, which is what an unopened picker shows.
  """
  def matching(queryable, term, limit) when term in [nil, ""],
    do: queryable |> ordered_by_display() |> limit(^limit)

  def matching(queryable, term, limit) do
    pattern = Like.contains(term)

    queryable
    |> where(
      [groups: g],
      ilike(g.display, ^pattern) or ilike(g.external_group_id, ^pattern)
    )
    |> ordered_by_display()
    |> limit(^limit)
  end

  def lock_for_update(queryable), do: lock(queryable, "FOR NO KEY UPDATE")

  def count_by_provider(queryable \\ all()) do
    queryable
    |> group_by([groups: g], g.provider_id)
    |> select([groups: g], {g.provider_id, count(g.id)})
  end

  def offset_page(queryable, offset, limit),
    do: queryable |> offset(^offset) |> limit(^limit)

  # Keyset order for the paged readout. `display` and `external_group_id` are
  # both optional (SCIM requires one of them, not both) and a NULL never
  # compares, so neither can carry a cursor — the arrival pair can: the
  # directory's push order, tie-broken by the UUIDv7 the SCIM resource id is.
  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:groups, :asc, :inserted_at}, {:groups, :asc, :id}]

  @impl Emisar.Repo.Query
  def preloads, do: []

  @impl Emisar.Repo.Query
  def filters do
    [
      %Filter{
        name: :search,
        title: "Group name or ID",
        type: :string,
        fun: fn queryable, term ->
          pattern = Like.contains(term)

          {queryable,
           dynamic(
             [groups: group],
             ilike(group.display, ^pattern) or ilike(group.external_group_id, ^pattern) or
               ilike(fragment("?::text", group.id), ^pattern)
           )}
        end
      }
    ]
  end
end
