defmodule Emisar.Repo.Migrations.IndexTheRecoverySweepPredicates do
  use Ecto.Migration

  # Built CONCURRENTLY: bin/migrate runs before an instance serves, so an
  # ordinary CREATE INDEX on a populated table holds a write lock for as long
  # as the build takes. Concurrent builds cannot run inside a transaction.
  @disable_ddl_transaction true
  @disable_migration_lock true

  # Three recurring sweeps ran scans that grow with all-time history even when
  # they find nothing — the slow-queries-on-an-idle-deployment class:
  #
  # 1. DispatchTimeout's list_running_runs filters status IN
  #    ('running','cancelling') every 60s, but the in-flight partial predicate
  #    (20260703000000) predates the cancelling status, so the planner cannot
  #    prove the query is covered and sequential-scans action_runs. Recreate
  #    the partial with cancelling included, under the same name.
  # 2. The 5s runbook-recovery callback pass joins terminal action_runs to
  #    running execution items. No index leads with the items' status, so the
  #    cheap side — the handful of in-flight items — could never drive the
  #    plan. A near-empty partial over running items hands the planner that
  #    side; action_runs_runbook_item_attempt_index serves the join back.
  # 3. The same 5s tick scrubs raw inputs from terminal executions
  #    (status IN (...) AND inputs_raw IS NOT NULL, ordered by inserted_at,
  #    id). Scrubbing clears inputs_raw, so this partial stays near-empty by
  #    construction while matching the predicate and order exactly.
  def up do
    execute("DROP INDEX CONCURRENTLY IF EXISTS action_runs_in_flight_idx")

    create index(:action_runs, [:status, :queued_at],
             where: "status IN ('pending', 'sent', 'running', 'cancelling')",
             name: :action_runs_in_flight_idx,
             concurrently: true
           )

    create index(:runbook_execution_items, [:id],
             where: "status = 'running'",
             name: :runbook_execution_items_running_callback_idx,
             concurrently: true
           )

    create index(:runbook_executions, [:inserted_at, :id],
             where: "status IN ('succeeded', 'halted', 'cancelled') AND inputs_raw IS NOT NULL",
             name: :runbook_executions_unscrubbed_terminal_idx,
             concurrently: true
           )
  end

  def down do
    drop_if_exists index(:runbook_executions, [:inserted_at, :id],
                     name: :runbook_executions_unscrubbed_terminal_idx,
                     concurrently: true
                   )

    drop_if_exists index(:runbook_execution_items, [:id],
                     name: :runbook_execution_items_running_callback_idx,
                     concurrently: true
                   )

    execute("DROP INDEX CONCURRENTLY IF EXISTS action_runs_in_flight_idx")

    create index(:action_runs, [:status, :queued_at],
             where: "status IN ('pending', 'sent', 'running')",
             name: :action_runs_in_flight_idx,
             concurrently: true
           )
  end
end
