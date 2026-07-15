defmodule Emisar.Repo.Migrations.AddOutputTruncationToActionRuns do
  use Ecto.Migration

  def change do
    alter table(:action_runs) do
      add :stdout_truncated, :boolean, null: false, default: false
      add :stderr_truncated, :boolean, null: false, default: false
    end
  end
end
