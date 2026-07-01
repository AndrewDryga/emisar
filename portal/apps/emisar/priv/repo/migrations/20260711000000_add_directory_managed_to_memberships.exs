defmodule Emisar.Repo.Migrations.AddDirectoryManagedToMemberships do
  use Ecto.Migration

  # Domain-owned enforcement of the synced-role lock (was web-handler-only): a
  # membership whose role a directory sync owns (SCIM group->role recompute) is
  # `directory_managed`, so `Accounts.update_membership_role` rejects an operator's
  # role change independently of the UI. Set by the sync write path; cleared when
  # SCIM is disabled for the provider.
  def up do
    alter table(:memberships) do
      add :directory_managed, :boolean, null: false, default: false
    end

    # Backfill: lock members whose role a currently-scim-enabled provider syncs,
    # so the enforcement applies to existing directory members immediately (not
    # only after their next sync).
    execute("""
    UPDATE memberships m SET directory_managed = true
    WHERE EXISTS (
      SELECT 1
      FROM user_identities ui
      JOIN identity_providers p ON p.id = ui.provider_id
      WHERE ui.user_id = m.user_id
        AND ui.account_id = m.account_id
        AND ui.deleted_at IS NULL
        AND p.scim_enabled = true
    )
    """)
  end

  def down do
    alter table(:memberships) do
      remove :directory_managed
    end
  end
end
