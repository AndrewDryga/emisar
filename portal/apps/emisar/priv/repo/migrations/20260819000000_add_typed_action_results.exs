defmodule Emisar.Repo.Migrations.AddTypedActionResults do
  use Ecto.Migration

  def change do
    alter table(:catalog_runner_actions) do
      add :output_schema, :map
    end

    alter table(:action_runs) do
      add :structured_output, :map
      add :structured_output_expected, :boolean, null: false, default: false
      # The schema the run was authorized against. Pack-version rows mutate on
      # re-trust, so result validation must not re-read the catalog.
      add :output_schema_snapshot, :map
    end
  end
end
