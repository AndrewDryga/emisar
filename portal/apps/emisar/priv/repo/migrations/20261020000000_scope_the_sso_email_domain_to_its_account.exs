defmodule Emisar.Repo.Migrations.ScopeTheSSOEmailDomainToItsAccount do
  use Ecto.Migration

  # Built CONCURRENTLY: bin/migrate runs before an instance serves, so an
  # ordinary CREATE INDEX holds a write lock for as long as the build takes.
  # Concurrent builds cannot run inside a transaction.
  @disable_ddl_transaction true
  @disable_migration_lock true

  # `allowed_email_domain` was globally unique across tenants, justified by a
  # sign-in discovery that was never built: the column's only reader is the
  # per-provider JIT restriction (`SSO.ensure_email_domain_allowed/2`), which
  # needs no uniqueness at all. Global uniqueness therefore bought nothing and
  # cost a cross-tenant coupling — one account claiming "bigcorp.com" left the
  # real bigcorp tenant unable to ever set it, refused by a constraint naming a
  # row in a workspace it cannot see. Ownership of a domain is unproven either
  # way (no TXT record, no email challenge), so the key becomes the account's.
  #
  # The narrower index cannot find a duplicate: every pair it covers was already
  # unique on the domain alone under the same predicate.
  def up do
    create unique_index(:sso_identity_providers, [:account_id, :allowed_email_domain],
             where: "enabled AND deleted_at IS NULL AND allowed_email_domain IS NOT NULL",
             name: :sso_identity_providers_account_email_domain_enabled_index,
             concurrently: true
           )

    drop_if_exists index(:sso_identity_providers, [:allowed_email_domain],
                     name: :sso_identity_providers_allowed_email_domain_enabled_index,
                     concurrently: true
                   )
  end

  # Only reversible while no two accounts have claimed the same domain — which
  # is exactly the state `up` exists to allow.
  def down do
    create unique_index(:sso_identity_providers, [:allowed_email_domain],
             where: "enabled AND deleted_at IS NULL AND allowed_email_domain IS NOT NULL",
             name: :sso_identity_providers_allowed_email_domain_enabled_index,
             concurrently: true
           )

    drop_if_exists index(:sso_identity_providers, [:account_id, :allowed_email_domain],
                     name: :sso_identity_providers_account_email_domain_enabled_index,
                     concurrently: true
                   )
  end
end
