defmodule Emisar.Repo.Migrations.BoundRunProgressIngestion do
  use Ecto.Migration

  def change do
    alter table(:action_runs) do
      # Durable per-run progress budget, incremented atomically under the run's
      # row lock on each accepted progress chunk (`Runs.append_event`). An
      # authenticated-but-hostile runner can otherwise append unbounded
      # distinct-seq events (each already payload-capped at 256 KiB) and fan
      # each onto the run's PubSub topic — a durable count/byte ceiling bounds
      # both the table and the socket fan-out.
      add :progress_event_count, :integer, null: false, default: 0
      add :progress_byte_count, :bigint, null: false, default: 0
    end

    # seq is runner-supplied and 1-based (the runner emits seq=1 for a run's
    # first chunk); a non-positive seq is malformed. Backstops the changeset
    # guard so a writer bypassing it still can't persist seq <= 0.
    create constraint(:action_run_events, :action_run_events_seq_positive, check: "seq > 0")
  end
end
