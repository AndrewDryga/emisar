defmodule Emisar.Repo.Migrations.AddExecutedCommandToActionRuns do
  use Ecto.Migration

  # The exact shell command the runner executed (sensitive arg values
  # redacted runner-side), captured off the action_result envelope so an
  # operator can see precisely what ran. The action_runs table already
  # shipped (20260520000005), so this is a standalone corrective add.
  def change do
    alter table(:action_runs) do
      add :executed_command, :text
    end
  end
end
