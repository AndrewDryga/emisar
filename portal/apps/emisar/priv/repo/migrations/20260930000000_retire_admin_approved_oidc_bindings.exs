defmodule Emisar.Repo.Migrations.RetireAdminApprovedOidcBindings do
  @moduledoc """
  An admin-approved OIDC identifier may share an identity row with the SCIM
  lifecycle for the same person. Deleting that row ends directory management;
  replacing the identifier with the SCIM external id can collide with a real
  OIDC subject and would make the directory value a login credential again.

  Keep the two authorities separate: retirement disables only the OIDC binding
  while preserving its historical value and the row for SCIM. Active-binding
  uniqueness releases authentication ownership for the provider's current user.
  """
  use Ecto.Migration

  @normalize_legacy_sql """
  UPDATE sso_user_identities AS identity
  SET created_by = 'admin',
      updated_at = now()
  FROM sso_identity_providers AS provider
  WHERE provider.id = identity.provider_id
    AND provider.account_id = identity.account_id
    AND identity.deleted_at IS NULL
    AND identity.created_by = 'provider'
    AND identity.provisioned_via = 'scim'
    AND identity.scim_external_id IS NOT NULL
    AND identity.provider_identifier <> identity.scim_external_id
    AND identity.claims->>provider.identifier_claim = identity.provider_identifier
  """

  @retire_sql """
  WITH candidates AS MATERIALIZED (
    SELECT identity.id
    FROM sso_user_identities AS identity
    WHERE identity.deleted_at IS NULL
      AND identity.provider_identifier_retired_at IS NULL
      AND identity.created_by = 'admin'
      AND EXISTS (
        SELECT 1
        FROM account_memberships AS membership
        WHERE membership.user_id = identity.user_id
          AND membership.deleted_at IS NULL
          AND membership.disabled_at IS NULL
          AND membership.account_id <> identity.account_id
      )
  ),
  preserved AS (
    UPDATE sso_user_identities AS identity
    SET provider_identifier_retired_at = now(),
        updated_at = now()
    FROM candidates
    WHERE identity.id = candidates.id
      AND identity.scim_external_id IS NOT NULL
    RETURNING identity.id
  ),
  removed AS (
    UPDATE sso_user_identities AS identity
    SET deleted_at = now(),
        updated_at = now()
    FROM candidates
    WHERE identity.id = candidates.id
      AND identity.scim_external_id IS NULL
    RETURNING identity.id
  ),
  affected AS (
    SELECT id FROM preserved
    UNION ALL
    SELECT id FROM removed
  )
  DELETE FROM auth_user_tokens AS token
  USING affected
  WHERE token.context = 'session'
    AND token.user_identity_id = affected.id
  """

  @doc false
  def normalize_legacy_sql, do: @normalize_legacy_sql

  @doc false
  def retire_sql, do: @retire_sql

  def up do
    alter table(:sso_user_identities) do
      add :provider_identifier_retired_at, :utc_datetime_usec
    end

    flush()

    # Older native-SCIM rebinds changed the identifier without recording that an
    # emisar administrator now owned the OIDC binding. Normalize that provenance
    # even when the user is still single-account, so a later activation can
    # enforce the same rule without reinterpreting mutable provider configuration.
    # Do not broaden this to oidc_jit rows: an ordinary OIDC-first identity later
    # linked to a differing SCIM externalId has the same stored shape as a later
    # historical rebind. There were no production SSO/SCIM rows to repair, and
    # future approvals stamp `created_by = admin` directly.
    execute(@normalize_legacy_sql)
    execute(@retire_sql)
  end

  # Once a retired subject has been assigned to its current owner, the old
  # schema cannot represent both that active login and the preserved SCIM row.
  def down do
    raise "retired OIDC bindings cannot be represented safely by the old schema"
  end
end
