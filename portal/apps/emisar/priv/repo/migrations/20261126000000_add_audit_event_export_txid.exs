defmodule Emisar.Repo.Migrations.AddAuditEventExportTxid do
  use Ecto.Migration

  # The SIEM export resumed strictly after the last `(occurred_at, id)` it
  # served, but `occurred_at` is stamped when the changeset is built and the
  # row becomes visible only at commit. A transaction that stamped earlier and
  # committed after a poll sorted behind the issued cursor and was never
  # exported. The export now orders by the writing transaction's ID and serves
  # only rows below the snapshot's xmin, where every writer has finished.
  #
  # Existing rows get txid 0, so they export first, in ID order (UUIDv7 insert
  # order). The constant default is metadata-only; the real default applies to
  # every row written after this migration.
  def up do
    alter table(:audit_events) do
      add :txid, :xid8, null: false, default: fragment("'0'::xid8")
    end

    execute("ALTER TABLE audit_events ALTER COLUMN txid SET DEFAULT pg_current_xact_id()")

    create index(:audit_events, [:account_id, :txid, :id], name: :audit_events_account_export_idx)
  end

  def down do
    drop index(:audit_events, [:account_id, :txid, :id], name: :audit_events_account_export_idx)

    alter table(:audit_events) do
      remove :txid
    end
  end
end
