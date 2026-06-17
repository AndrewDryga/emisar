defmodule Emisar.SSO.IdentityProvider.Query do
  use Emisar, :query
  alias Emisar.SSO.IdentityProvider

  def all,
    do: from(providers in IdentityProvider, as: :providers)

  def not_deleted(queryable \\ all()),
    do: where(queryable, [providers: p], is_nil(p.deleted_at))

  def by_id(queryable, id),
    do: where(queryable, [providers: p], p.id == ^id)

  def excluding_id(queryable, id),
    do: where(queryable, [providers: p], p.id != ^id)

  def by_account_id(queryable, account_id),
    do: where(queryable, [providers: p], p.account_id == ^account_id)

  def enabled(queryable),
    do: where(queryable, [providers: p], p.enabled)

  # The SCIM bearer lookup — resolves the live provider by its token prefix.
  def by_scim_token_prefix(queryable, prefix),
    do: where(queryable, [providers: p], p.scim_token_prefix == ^prefix)

  def scim_enabled(queryable),
    do: where(queryable, [providers: p], p.scim_enabled)

  def ordered_by_name(queryable),
    do: order_by(queryable, [providers: p], asc: p.name)

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:providers, :asc, :name}, {:providers, :asc, :id}]
end
