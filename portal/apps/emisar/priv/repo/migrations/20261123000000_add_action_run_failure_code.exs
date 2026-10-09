defmodule Emisar.Repo.Migrations.AddActionRunFailureCode do
  use Ecto.Migration

  def change do
    alter table(:action_runs) do
      add :failure_code, :string
    end
  end
end
