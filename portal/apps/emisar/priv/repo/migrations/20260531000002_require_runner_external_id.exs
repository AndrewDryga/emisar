defmodule Emisar.Repo.Migrations.RequireRunnerExternalId do
  use Ecto.Migration

  def up do
    # Backfill any rows that slipped through `Runners.create_runner/2`
    # (which didn't cast :external_id). `gen_random_uuid()` is built-in
    # on Postgres 13+.
    execute("UPDATE runners SET external_id = gen_random_uuid()::text WHERE external_id IS NULL")

    alter table(:runners) do
      modify :external_id, :string, null: false
    end
  end

  def down do
    alter table(:runners) do
      modify :external_id, :string, null: true
    end
  end
end
