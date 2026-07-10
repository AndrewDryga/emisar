defmodule Emisar.Repo.Migrations.AddHaltStateToRunbookExecutions do
  use Ecto.Migration

  def change do
    alter table(:runbook_executions) do
      add :status, :string, null: false, default: "active"
      add :halted_at, :utc_datetime_usec
    end
  end
end
