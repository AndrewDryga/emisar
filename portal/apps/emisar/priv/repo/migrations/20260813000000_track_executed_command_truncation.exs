defmodule Emisar.Repo.Migrations.TrackExecutedCommandTruncation do
  use Ecto.Migration

  def change do
    alter table(:action_runs) do
      add :executed_command_truncated, :boolean, null: false, default: false
    end
  end
end
