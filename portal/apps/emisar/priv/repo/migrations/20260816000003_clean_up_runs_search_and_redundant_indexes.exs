defmodule Emisar.Repo.Migrations.CleanUpRunsSearchAndRedundantIndexes do
  use Ecto.Migration

  # Three plain indexes are covered by a unique index on the same leading
  # column and only slow writes. The runs action_id contains-search
  # (ILIKE '%term%') cannot use a B-tree; a trigram GIN index serves it.
  # pg_trgm ships with Postgres (and Cloud SQL); the extension stays on
  # rollback since other objects may come to depend on it.

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm"

    drop index(:action_runs, [:mcp_operation_record_id],
           name: :action_runs_mcp_operation_record_id_index
         )

    drop index(:approval_decisions, [:request_id], name: :approval_decisions_request_id_index)

    drop index(:runbook_executions, [:mcp_operation_record_id],
           name: :runbook_executions_mcp_operation_record_id_index
         )

    execute """
    CREATE INDEX action_runs_action_id_trgm_index
    ON action_runs USING gin (action_id gin_trgm_ops)
    """
  end

  def down do
    execute "DROP INDEX action_runs_action_id_trgm_index"

    create index(:runbook_executions, [:mcp_operation_record_id],
             name: :runbook_executions_mcp_operation_record_id_index
           )

    create index(:approval_decisions, [:request_id], name: :approval_decisions_request_id_index)

    create index(:action_runs, [:mcp_operation_record_id],
             name: :action_runs_mcp_operation_record_id_index
           )
  end
end
