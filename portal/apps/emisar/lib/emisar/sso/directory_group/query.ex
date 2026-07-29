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

  def by_external_group_id(queryable, external_group_id),
    do: where(queryable, [groups: g], g.external_group_id == ^external_group_id)

  @doc "The `displayName eq` probe Entra sends before every push, matched case-insensitively."
  def by_display(queryable, display) when is_binary(display) do
    where(
      queryable,
      [groups: g],
      fragment("lower(coalesce(?, ?)) = lower(?)", g.display, g.external_group_id, ^display)
    )
  end

  def ordered_by_external_group_id(queryable),
    do: order_by(queryable, [groups: g], asc: g.external_group_id)

  @impl Emisar.Repo.Query
  def cursor_fields, do: [{:groups, :asc, :external_group_id}, {:groups, :asc, :id}]

  @impl Emisar.Repo.Query
  def preloads, do: []
end
