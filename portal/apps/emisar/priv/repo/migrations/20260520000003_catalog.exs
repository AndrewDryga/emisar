defmodule Emisar.Repo.Migrations.Catalog do
  use Ecto.Migration

  def change do
    # Pack records are what the runner advertises on connect. We
    # snapshot the runner_state.packs map into rows here so cloud-side
    # queries (which packs are installed across the fleet, drift
    # detection) don't need to scan every runner's `packs` column.
    create table(:pack_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :pack_id, :string, null: false
      add :version, :string, null: false
      add :hash, :string
      add :first_seen_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:pack_versions, [:account_id, :pack_id, :version, :hash])
    create index(:pack_versions, [:account_id, :pack_id])

    # Actions advertised by runners. One row per (runner, action_id) so
    # we can answer "what can this specific runner do right now?".
    # Schemas, side_effects, examples — everything the runner
    # advertised — are stored as JSON for fidelity to the wire shape.
    create table(:runner_actions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :runner_id, references(:runners, type: :binary_id, on_delete: :delete_all), null: false

      add :action_id, :string, null: false
      add :pack_id, :string
      add :title, :string, null: false
      add :kind, :string, null: false
      add :risk, :string, null: false
      add :description, :text
      add :side_effects, {:array, :string}, null: false, default: []
      add :args_schema, :map, null: false, default: %{}
      add :examples, {:array, :map}, null: false, default: []

      add :first_seen_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:runner_actions, [:runner_id, :action_id])
    create index(:runner_actions, [:account_id, :action_id])
    create index(:runner_actions, [:account_id, :risk])
  end
end
