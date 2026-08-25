defmodule Emisar.SSO.GroupRoleMapping.Query do
  use Emisar, :query
  alias Emisar.SSO.GroupRoleMapping

  def all,
    do: from(mappings in GroupRoleMapping, as: :mappings)

  def not_deleted(queryable \\ all()),
    do: where(queryable, [mappings: m], is_nil(m.deleted_at))

  def by_id(queryable, id),
    do: where(queryable, [mappings: m], m.id == ^id)

  def by_account_id(queryable, account_id),
    do: where(queryable, [mappings: m], m.account_id == ^account_id)

  def by_provider_id(queryable, provider_id),
    do: where(queryable, [mappings: m], m.provider_id == ^provider_id)

  def by_directory_group_id(queryable, directory_group_id),
    do: where(queryable, [mappings: m], m.directory_group_id == ^directory_group_id)

  def with_preloaded_directory_group(queryable) do
    preload(queryable, directory_group: ^Emisar.SSO.DirectoryGroup.Query.all())
  end

  def lock_for_update(queryable), do: lock(queryable, "FOR NO KEY UPDATE")

  # {provider_id, count} rows — the per-connection group-mapping tallies for the
  # overview. Group by provider so one query covers every connection.
  def count_by_provider(queryable) do
    queryable
    |> group_by([mappings: m], m.provider_id)
    |> select([mappings: m], {m.provider_id, count(m.id)})
  end

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:mappings, :asc, :directory_group_id}, {:mappings, :asc, :id}]
end
