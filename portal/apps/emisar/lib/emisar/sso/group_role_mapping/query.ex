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

  def by_external_group_id(queryable, external_group_id),
    do: where(queryable, [mappings: m], m.external_group_id == ^external_group_id)

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:mappings, :asc, :external_group_id}, {:mappings, :asc, :id}]
end
