defmodule Emisar.Repo.Migrations.AddRunnerActionAdmissionEvidence do
  use Ecto.Migration

  def change do
    alter table(:catalog_runner_actions) do
      add :admission_allowed, :boolean
    end
  end
end
