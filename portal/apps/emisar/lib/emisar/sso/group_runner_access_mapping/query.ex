defmodule Emisar.SSO.GroupRunnerAccessMapping.Query do
  use Emisar, :query

  def all do
    from(mappings in Emisar.SSO.GroupRunnerAccessMapping, as: :group_runner_access_mappings)
  end

  def not_deleted(queryable \\ all()) do
    where(queryable, [group_runner_access_mappings: m], is_nil(m.deleted_at))
  end

  def by_id(queryable \\ all(), id),
    do: where(queryable, [group_runner_access_mappings: m], m.id == ^id)

  def by_account_id(queryable \\ all(), account_id),
    do: where(queryable, [group_runner_access_mappings: m], m.account_id == ^account_id)

  def by_provider_id(queryable \\ all(), provider_id) do
    where(queryable, [group_runner_access_mappings: m], m.provider_id == ^provider_id)
  end

  @impl Emisar.Repo.Query
  def cursor_fields do
    [
      {:group_runner_access_mappings, :asc, :external_group_id},
      {:group_runner_access_mappings, :asc, :id}
    ]
  end
end
