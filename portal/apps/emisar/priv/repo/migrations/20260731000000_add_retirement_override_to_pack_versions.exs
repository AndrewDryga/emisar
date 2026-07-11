defmodule Emisar.Repo.Migrations.AddRetirementOverrideToPackVersions do
  use Ecto.Migration

  def change do
    alter table(:pack_versions) do
      add :retirement_overridden_at, :utc_datetime_usec

      add :retirement_overridden_by_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)
    end
  end
end
