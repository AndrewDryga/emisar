defmodule Emisar.Repo.Migrations.DropEventCursors do
  use Ecto.Migration

  # The runner-event-cursor outbox sidecar was never wired up: the runner
  # socket acks events in-memory, not via this table, so the cloud never
  # wrote or read it. The table shipped in 20260520000007, so this is a
  # standalone corrective drop rather than an edit-in-place. `down`
  # mirrors that original `create table` block so the migration reverses.
  def up do
    drop table(:runner_event_cursors)
  end

  def down do
    create table(:runner_event_cursors, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :runner_id, references(:runners, type: :binary_id, on_delete: :delete_all), null: false
      add :event_id, :string, null: false
      add :acked_at, :utc_datetime_usec, null: false
    end

    create unique_index(:runner_event_cursors, [:runner_id, :event_id])
  end
end
