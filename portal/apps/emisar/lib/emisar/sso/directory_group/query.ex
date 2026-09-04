defmodule Emisar.SSO.DirectoryGroup.Query do
  use Emisar, :query
  alias Emisar.SSO.DirectoryGroup

  def all, do: from(groups in DirectoryGroup, as: :groups)

  def not_deleted(queryable \\ all()),
    do: where(queryable, [groups: g], is_nil(g.deleted_at))

  def none(queryable), do: where(queryable, false)

  def by_account_id(queryable \\ all(), account_id),
    do: where(queryable, [groups: g], g.account_id == ^account_id)

  def by_provider_id(queryable \\ all(), provider_id),
    do: where(queryable, [groups: g], g.provider_id == ^provider_id)

  def by_id(queryable, id),
    do: where(queryable, [groups: g], g.id == ^id)

  def by_external_group_id(queryable, external_group_id),
    do: where(queryable, [groups: g], g.external_group_id == ^external_group_id)

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

  def lock_for_update(queryable), do: lock(queryable, "FOR NO KEY UPDATE")

  def count_by_provider(queryable \\ all()) do
    queryable
    |> group_by([groups: g], g.provider_id)
    |> select([groups: g], {g.provider_id, count(g.id)})
  end

  def offset_page(queryable, offset, limit),
    do: queryable |> offset(^offset) |> limit(^limit)

  @impl Emisar.Repo.Query
  def preloads, do: []
end
