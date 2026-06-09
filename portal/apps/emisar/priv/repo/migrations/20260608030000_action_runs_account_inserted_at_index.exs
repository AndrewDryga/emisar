defmodule Emisar.Repo.Migrations.ActionRunsAccountInsertedAtIndex do
  use Ecto.Migration

  # The default /app/runs page (`Runs.list_runs/2`) orders by `inserted_at
  # DESC`, scoped to `account_id`, with no status filter. The existing
  # composite indexes are `(account_id, status)`, `(account_id, action_id)`,
  # and `(runner_id, status)` — none of which serve the unfiltered ordered
  # list, so it falls back to a scan + sort per page. Add the matching
  # `(account_id, inserted_at)` index. Standalone corrective migration: the
  # original `runs_and_events` migration has already shipped to prod.
  def change do
    create index(:action_runs, [:account_id, :inserted_at])
  end
end
