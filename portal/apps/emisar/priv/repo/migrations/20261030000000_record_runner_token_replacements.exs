defmodule Emisar.Repo.Migrations.RecordRunnerTokenReplacements do
  use Ecto.Migration

  def change do
    alter table(:runner_tokens) do
      add :replaces_id, references(:runner_tokens, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:runner_tokens, [:replaces_id])
  end
end
