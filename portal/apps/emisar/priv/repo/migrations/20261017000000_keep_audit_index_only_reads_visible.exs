defmodule Emisar.Repo.Migrations.KeepAuditIndexOnlyReadsVisible do
  use Ecto.Migration

  def up do
    # audit_events is append-only between retention sweeps. The default insert
    # trigger waited for roughly 20% of the table plus 1,000 new rows, leaving
    # recent index entries without all-visible coverage for days. The Audit
    # total then had to revisit the heap despite using the right account index.
    execute("""
    ALTER TABLE audit_events SET (
      autovacuum_vacuum_insert_scale_factor = 0.02,
      autovacuum_vacuum_insert_threshold = 500
    )
    """)
  end

  def down do
    execute("""
    ALTER TABLE audit_events RESET (
      autovacuum_vacuum_insert_scale_factor,
      autovacuum_vacuum_insert_threshold
    )
    """)
  end
end
