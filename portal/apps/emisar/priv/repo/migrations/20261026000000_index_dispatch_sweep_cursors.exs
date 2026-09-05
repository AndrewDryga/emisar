defmodule Emisar.Repo.Migrations.IndexDispatchSweepCursors do
  use Ecto.Migration
  alias Emisar.Release.IndexRecovery

  @disable_ddl_transaction true
  @disable_migration_lock true

  # The status/queued_at index still serves age-filtered reads. These small
  # partial indexes serve the sweep's cursor orders without scanning completed
  # history or sorting the remaining pending queue on every page. Recover a
  # failed concurrent build before recording this migration as applied.
  def up do
    IndexRecovery.ensure_index(repo(), prefix(), "action_runs", ~w(id),
      name: "action_runs_in_flight_sweep_id_idx",
      predicate: :in_flight
    )

    IndexRecovery.ensure_index(repo(), prefix(), "action_runs", ~w(runner_id id),
      name: "action_runs_pending_sweep_runner_id_idx",
      predicate: :pending
    )
  end

  def down do
    IndexRecovery.drop_index(repo(), prefix(), "action_runs", ~w(runner_id id),
      name: "action_runs_pending_sweep_runner_id_idx",
      predicate: :pending
    )

    IndexRecovery.drop_index(repo(), prefix(), "action_runs", ~w(id),
      name: "action_runs_in_flight_sweep_id_idx",
      predicate: :in_flight
    )
  end
end
