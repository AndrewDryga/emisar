defmodule Emisar.Repo.Migrations.ScopeOidcIdentifierUniquenessToActiveBindings do
  @moduledoc """
  A retired identifier is no longer authentication authority and must not let a
  preserved SCIM row squat on its real owner's OIDC subject. Build the active
  binding index before dropping the stronger predecessor so uniqueness is never
  absent while the populated table is writable.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create unique_index(
             :sso_user_identities,
             [:account_id, :provider_id, :provider_identifier],
             where: "deleted_at IS NULL AND provider_identifier_retired_at IS NULL",
             name: :sso_user_identities_active_provider_identifier_index,
             concurrently: true
           )

    execute("DROP INDEX CONCURRENTLY IF EXISTS sso_user_identities_provider_identifier_index")
  end

  # A retired subject may have acquired a new active owner, so rebuilding the
  # stronger predecessor can violate both uniqueness and the trust decision.
  def down do
    raise "active-only OIDC identifier uniqueness cannot be reversed safely"
  end
end
