defmodule Emisar.Repo.Migrations.TrackPrimaryExecutableAvailability do
  use Ecto.Migration

  def change do
    alter table(:catalog_runner_actions) do
      add :primary_executable_available, :boolean
      add :missing_executable, :string
    end

    create constraint(:catalog_runner_actions, :missing_executable_requires_unavailable,
             check: "missing_executable IS NULL OR primary_executable_available = false"
           )
  end
end
