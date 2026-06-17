defmodule Emisar.Repo.Migrations.ActionRunsApiKeyAndRunbookInsertedAtIndexes do
  use Ecto.Migration

  # Two hot reads on action_runs sort by `inserted_at` within a single-column
  # equality scope, but no index pairs that column with inserted_at, so each
  # falls back to a scan + sort:
  #
  #   * MCP `recent_runs` scope::own — `Runs.list_recent_runs/2` filters
  #     `api_key_id = ?` and orders `inserted_at DESC`. The only api_key_id
  #     index is the unique `(api_key_id, idempotency_key)`, which can't serve
  #     the ordered list.
  #   * `Runs.fetch_active_runbook_execution/2` — filters `runbook_id = ?`,
  #     orders `inserted_at DESC`, LIMIT 1. The lone `(runbook_id)` index
  #     matches the filter but then sorts.
  #
  # Add the matching composites. `(runbook_id, inserted_at)` subsumes the
  # single-column `(runbook_id)` index (a B-tree serves leading-column lookups),
  # so drop that one rather than maintain two overlapping indexes on this
  # high-write table. Standalone corrective migration — `runs_and_events` has
  # already shipped (mirrors action_runs_account_inserted_at_index).
  def change do
    create index(:action_runs, [:api_key_id, :inserted_at])
    create index(:action_runs, [:runbook_id, :inserted_at])
    drop index(:action_runs, [:runbook_id])
  end
end
