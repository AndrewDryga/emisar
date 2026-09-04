defmodule Emisar.Repo.Migrations.IndexTheAuditConsoleKeysetOrder do
  use Ecto.Migration

  # Built CONCURRENTLY: bin/migrate runs before an instance serves, and
  # audit_events is the append-only, unbounded-per-tenant table. Concurrent
  # builds cannot run inside a transaction.
  @disable_ddl_transaction true
  @disable_migration_lock true

  # audit_events has two readers wanting opposite tie-breaks. 20260921000000
  # gave the SIEM export its exact shape — (account_id, occurred_at ASC, id ASC)
  # — and left the console's keyset with none: `cursor_fields/0` is
  # `{occurred_at DESC, id ASC}`, and a backward scan of an all-ascending index
  # yields `id DESC` inside a timestamp tie, so the row comparison degrades to a
  # post-scan filter plus an incremental sort. One index cannot carry both
  # tie-breaks, so the console gets its own; the export's index stays, because
  # `ordered_for_export/1` is a live reader of it.
  #
  # `create_if_not_exists`, because a CREATE INDEX CONCURRENTLY that fails
  # part-way leaves an INVALID index of that name behind: a plain retry then
  # fails on the duplicate and the release boot-loops until someone drops it by
  # hand.
  def up do
    create_if_not_exists index(:audit_events, [:account_id, "occurred_at DESC", "id ASC"],
                           name: :audit_events_account_console_keyset_idx,
                           concurrently: true
                         )
  end

  def down do
    drop_if_exists index(:audit_events, [:account_id, "occurred_at DESC", "id ASC"],
                     name: :audit_events_account_console_keyset_idx
                   )
  end
end
