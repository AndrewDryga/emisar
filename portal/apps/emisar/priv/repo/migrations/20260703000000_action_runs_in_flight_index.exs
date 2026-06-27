defmodule Emisar.Repo.Migrations.ActionRunsInFlightIndex do
  use Ecto.Migration

  # The RunDispatchTimeout sweep runs every 60s with GLOBAL (no account_id)
  # predicates — `status IN ('pending','sent') AND queued_at < cutoff` and
  # `status IN ('running')`. Every existing action_runs index LEADS with
  # account_id/runner_id, so none can serve a status-leading global scan: Postgres
  # seq-scans the highest-cardinality append-only table once a minute, and the cost
  # creeps with every run ever dispatched. A PARTIAL index over just the in-flight
  # rows (a tiny minority of all-time runs) stays small; status leads (so the
  # running-only query seeks) and queued_at follows (so the stale query ranges) —
  # the sweep becomes an index scan. Corrective migration: action_runs is on prod.
  def change do
    create index(:action_runs, [:status, :queued_at],
             where: "status IN ('pending', 'sent', 'running')",
             name: :action_runs_in_flight_idx
           )
  end
end
