defmodule Emisar.Repo.Migrations.DropRunnerDbHeartbeat do
  use Ecto.Migration

  # Connection state moved to Phoenix.Presence (`Emisar.Runners.Presence`).
  # `status`, `action_load`, and `last_heartbeat_at` were the DB-side
  # heartbeat scaffolding — presence is the source of truth for "online
  # now", and action_load / last heartbeat live in presence metadata.
  # The runners table (20260520000002) already shipped, so this is a
  # standalone corrective drop rather than an edit-in-place.
  def change do
    drop index(:runners, [:account_id, :status])

    alter table(:runners) do
      remove :status, :string, null: false, default: "pending"
      remove :action_load, :integer, null: false, default: 0
      remove :last_heartbeat_at, :utc_datetime_usec
    end
  end
end
