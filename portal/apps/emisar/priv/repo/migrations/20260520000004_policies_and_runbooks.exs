defmodule Emisar.Repo.Migrations.PoliciesAndRunbooks do
  use Ecto.Migration

  def change do
    # The policy that decides whether each dispatched action runs,
    # needs approval, or is denied. Exactly one row per account — the
    # account_id unique index enforces the invariant at the DB level.
    # The runner never sees this; cloud evaluates it before sending
    # run_action.
    create table(:policies, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all), null: false

      add :rules, :map, null: false, default: %{}

      add :updated_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:policies, [:account_id])

    # Runbooks are cloud-side workflows that orchestrate multiple
    # action calls. The agent never sees a runbook; cloud expands it
    # into individual run_action messages. Versioning is identical to
    # policies — one row per (name, version).
    create table(:runbooks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all), null: false

      add :name, :string, null: false
      add :slug, :citext, null: false
      add :title, :string, null: false
      add :description, :text

      add :version, :integer, null: false, default: 1
      add :status, :string, null: false, default: "draft"

      # The structured definition: steps, args, when conditions,
      # final template. Mirrors the runbookspec.Runbook type the
      # earlier (deleted) agent-side runbook engine had.
      add :definition, :map, null: false

      add :created_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :archived_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:runbooks, [:account_id, :slug, :version])
    create index(:runbooks, [:account_id, :status])
  end
end
