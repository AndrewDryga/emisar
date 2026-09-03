defmodule Emisar.Repo.Migrations.IndexTheStaffAnalyticsRunWindow do
  use Ecto.Migration

  # Built CONCURRENTLY: bin/migrate runs before an instance serves, and an
  # ordinary CREATE INDEX on action_runs — the largest table in the product —
  # holds a write lock for the whole build. Concurrent builds cannot run inside
  # a transaction.
  @disable_ddl_transaction true
  @disable_migration_lock true

  # Every staff analytics aggregate (Emisar.Admin.Query) reads action_runs
  # across every tenant, filtered only by `inserted_at >= since`. Every other
  # action_runs index leads with account_id, api_key_id, runbook_id, or status,
  # so each of those aggregates was a sequential scan of the whole table — the
  # staff runtime dashboard stops working exactly when there is an incident to
  # triage. Leading with inserted_at serves the window; the two status-filtered
  # readers (recent_failures/2 and non_success_outcome_groups_since/2) take the
  # same range scan and filter within it.
  #
  # `create_if_not_exists`, because a CREATE INDEX CONCURRENTLY that fails
  # part-way leaves an INVALID index of that name behind: a plain retry then
  # fails on the duplicate and the release boot-loops until someone drops it by
  # hand.
  def up do
    create_if_not_exists index(:action_runs, [:inserted_at],
                           name: :action_runs_inserted_at_idx,
                           concurrently: true
                         )
  end

  def down do
    drop_if_exists index(:action_runs, [:inserted_at], name: :action_runs_inserted_at_idx)
  end
end
