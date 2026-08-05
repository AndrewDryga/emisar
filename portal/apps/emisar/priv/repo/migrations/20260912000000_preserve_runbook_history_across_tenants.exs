defmodule Emisar.Repo.Migrations.PreserveRunbookHistoryAcrossTenants do
  use Ecto.Migration

  # The original FK assumed memberships only ever soft-delete, so a CASCADE
  # could never fire. They hard-delete: `account_memberships.user_id` is ON
  # DELETE CASCADE, and erasing a user drops their memberships in EVERY
  # account. That cascaded through here and destroyed other tenants'
  # execution history — stages, items, action runs, events, and approvals.
  #
  # Match the sibling `action_runs.initiating_membership_id`, which is
  # nullable + nilify_all precisely so a hard-deleted user cannot drop an
  # execution's audit trail. Creation still requires the anchor (the
  # changeset validates it); only erasure clears it.

  def up do
    drop constraint(:runbook_executions, "runbook_executions_initiating_membership_id_fkey")

    alter table(:runbook_executions) do
      modify :initiating_membership_id, :binary_id, null: true
    end

    execute """
    ALTER TABLE runbook_executions
    ADD CONSTRAINT runbook_executions_initiating_membership_id_fkey
    FOREIGN KEY (initiating_membership_id)
    REFERENCES account_memberships (id) ON DELETE SET NULL
    """

    # The cascade was also doing the work of an index that never existed:
    # every membership delete sequentially scanned this table.
    create index(:runbook_executions, [:initiating_membership_id])
  end

  def down do
    drop index(:runbook_executions, [:initiating_membership_id])

    drop constraint(:runbook_executions, "runbook_executions_initiating_membership_id_fkey")

    alter table(:runbook_executions) do
      modify :initiating_membership_id, :binary_id, null: false
    end

    execute """
    ALTER TABLE runbook_executions
    ADD CONSTRAINT runbook_executions_initiating_membership_id_fkey
    FOREIGN KEY (initiating_membership_id)
    REFERENCES account_memberships (id) ON DELETE CASCADE
    """
  end
end
