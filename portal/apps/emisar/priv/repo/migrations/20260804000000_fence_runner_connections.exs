defmodule Emisar.Repo.Migrations.FenceRunnerConnections do
  use Ecto.Migration

  def change do
    alter table(:runners) do
      add :connection_generation, :bigint, null: false, default: 0
      add :connection_lease_id, :uuid
      add :connection_lease_expires_at, :utc_datetime_usec
    end

    alter table(:action_runs) do
      add :runner_connection_generation, :bigint
    end
  end
end
