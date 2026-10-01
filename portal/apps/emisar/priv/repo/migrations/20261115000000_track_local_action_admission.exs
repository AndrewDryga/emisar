defmodule Emisar.Repo.Migrations.TrackLocalActionAdmission do
  use Ecto.Migration

  def change do
    alter table(:catalog_runner_actions) do
      add(:local_admission_allowed, :boolean)
    end
  end
end
