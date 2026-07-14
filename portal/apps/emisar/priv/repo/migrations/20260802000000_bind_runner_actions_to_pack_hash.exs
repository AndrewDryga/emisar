defmodule Emisar.Repo.Migrations.BindRunnerActionsToPackHash do
  use Ecto.Migration

  def change do
    alter table(:runner_actions) do
      add :pack_hash, :string
      add :summary, :text
      add :search_terms, {:array, :string}, null: false, default: []
    end

    create index(:runner_actions, [:account_id, :pack_id, :pack_version, :pack_hash])
  end
end
