defmodule Emisar.Repo.Migrations.ReattributeSuspensionsTheRepairGuessed do
  @moduledoc """
  `20260829000000` backfilled `directory_provider_id` with `UPDATE … FROM
  sso_user_identities i WHERE i.user_id = m.user_id AND i.account_id =
  m.account_id`. Identities are unique per `(account, provider, user)`, not per
  `(account, user)` — an account running Okta AND Entra gives one person a live
  identity on each — so that join could match two rows and PostgreSQL picked one.
  It also never required the provider to still be syncing.

  A misattributed suspension is not cosmetic. `reinstate_membership` refuses a
  `directory_suspended` row on the reasoning that only the IdP which placed the
  hold may lift it, so the wrong owner means the connection that actually
  deactivated the person cannot reactivate them, while an unrelated one can.

  This re-attributes only where the answer is unambiguous — exactly one live
  identity, on a connection still syncing, that says the person is inactive.
  Anything left without a single owner is handed back to operators: the hold
  stays (`disabled_at` is untouched, because the directory's last word was that
  they are out) but it stops being the directory's to lift, so a human can
  recover a member nobody else can.
  """
  use Ecto.Migration

  def up do
    # Exactly one candidate: re-point the owner at it.
    execute """
    WITH owners AS (
      SELECT m.id AS membership_id,
             min(i.provider_id::text) AS provider_id,
             count(*) AS candidates
      FROM account_memberships m
      JOIN sso_user_identities i
        ON i.user_id = m.user_id
       AND i.account_id = m.account_id
       AND i.deleted_at IS NULL
       AND i.scim_active = false
      JOIN sso_identity_providers p
        ON p.id = i.provider_id
       AND p.deleted_at IS NULL
       AND p.scim_enabled = true
      WHERE m.directory_suspended = true
        AND m.deleted_at IS NULL
      GROUP BY m.id
    )
    UPDATE account_memberships m
    SET directory_provider_id = owners.provider_id::uuid,
        updated_at = now()
    FROM owners
    WHERE owners.membership_id = m.id
      AND owners.candidates = 1
      AND m.directory_provider_id IS DISTINCT FROM owners.provider_id::uuid
    """

    # No single owner left — ambiguous, or attributed to a connection that has
    # stopped syncing. Hand the hold to operators rather than leave a member
    # only a nonexistent authority may release.
    execute """
    UPDATE account_memberships m
    SET directory_suspended = false,
        directory_provider_id = NULL,
        updated_at = now()
    WHERE m.directory_suspended = true
      AND m.deleted_at IS NULL
      AND NOT EXISTS (
        SELECT 1
        FROM sso_user_identities i
        JOIN sso_identity_providers p
          ON p.id = i.provider_id
         AND p.deleted_at IS NULL
         AND p.scim_enabled = true
        WHERE i.user_id = m.user_id
          AND i.account_id = m.account_id
          AND i.deleted_at IS NULL
          AND i.scim_active = false
          AND i.provider_id = m.directory_provider_id
      )
    """
  end

  # No down. Re-guessing an owner is what this exists to undo, and restoring a
  # hold nobody can lift would put those members back where they were stuck.
  def down, do: :ok
end
