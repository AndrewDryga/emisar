defmodule Emisar.Repo.Migrations.MatchKeysetIndexesToCursorOrder do
  use Ecto.Migration

  # Built CONCURRENTLY: bin/migrate runs before an instance serves, so an
  # ordinary CREATE INDEX on a populated table holds a write lock for as long
  # as the build takes. Concurrent builds cannot run inside a transaction.
  @disable_ddl_transaction true
  @disable_migration_lock true

  # Both tables paginate by keyset, and neither index carried the tie-break
  # column its cursor declares. Postgres could still answer — backward-scan the
  # timestamp, then incremental-sort each same-timestamp group — but the row
  # comparison stayed a post-scan filter instead of an index condition.
  #
  # action_runs' cursor is the console feed's {inserted_at DESC, id ASC}, and
  # nothing else reads that ordering, so the index takes that exact shape: the
  # page becomes an index-only scan with the whole comparison in the Index Cond.
  #
  # audit_events has TWO consumers wanting opposite tie-break directions — the
  # console's {occurred_at DESC, id ASC} and the SIEM export's {occurred_at ASC,
  # id ASC}. One index cannot serve both tie-breaks, so it takes the export's
  # shape: the export re-walks the entire log page after page, while the console
  # reads 35 rows and sorts only within identical microsecond timestamps.
  #
  # Each replacement is a strict superset of the index it drops (same leading
  # columns, same directions), so every range and prefix lookup those served
  # still resolves — the same trade 20260918000000 made for prefix siblings.
  def up do
    create index(:action_runs, [:account_id, "inserted_at DESC", "id ASC"],
             name: :action_runs_account_keyset_idx,
             concurrently: true
           )

    execute("DROP INDEX CONCURRENTLY IF EXISTS action_runs_account_id_inserted_at_index")

    create index(:audit_events, [:account_id, :occurred_at, :id],
             name: :audit_events_account_keyset_idx,
             concurrently: true
           )

    execute("DROP INDEX CONCURRENTLY IF EXISTS audit_events_account_id_occurred_at_index")
  end

  def down do
    create index(:audit_events, [:account_id, :occurred_at],
             name: :audit_events_account_id_occurred_at_index,
             concurrently: true
           )

    drop_if_exists index(:audit_events, [:account_id, :occurred_at, :id],
                     name: :audit_events_account_keyset_idx,
                     concurrently: true
                   )

    create index(:action_runs, [:account_id, :inserted_at],
             name: :action_runs_account_id_inserted_at_index,
             concurrently: true
           )

    drop_if_exists index(:action_runs, [:account_id, "inserted_at DESC", "id ASC"],
                     name: :action_runs_account_keyset_idx,
                     concurrently: true
                   )
  end
end
