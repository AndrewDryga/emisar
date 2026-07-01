defmodule Emisar.Repo.Migrations.AddDirectorySuspendedToMemberships do
  use Ecto.Migration

  # Domain-owned enforcement of the "can't manually reinstate an IdP-deactivated
  # member" rule (was web-handler-only — the web passed `deactivated_in_idp?`
  # computed from the loaded identity's scim_active, and the domain trusted it; a
  # degraded identity load sent `false` and reinstated a member the IdP revoked).
  # `directory_suspended` records that a directory sync (SCIM `active:false` /
  # DELETE) owns the suspension, so `Accounts.reinstate_membership` refuses off the
  # locked row. Set by the SCIM deprovision write path; cleared when the IdP
  # reactivates (or a manual reinstate, which is only reachable when false).
  def up do
    alter table(:memberships) do
      add :directory_suspended, :boolean, null: false, default: false
    end

    # Backfill: members the IdP currently has deactivated (suspended here + a
    # scim_active:false identity for a directory provider) so the guard applies to
    # existing IdP-deactivated members immediately, not only after their next sync.
    execute("""
    UPDATE memberships m SET directory_suspended = true
    WHERE m.disabled_at IS NOT NULL
      AND EXISTS (
        SELECT 1
        FROM user_identities ui
        WHERE ui.user_id = m.user_id
          AND ui.account_id = m.account_id
          AND ui.deleted_at IS NULL
          AND ui.scim_active = false
      )
    """)
  end

  def down do
    alter table(:memberships) do
      remove :directory_suspended
    end
  end
end
