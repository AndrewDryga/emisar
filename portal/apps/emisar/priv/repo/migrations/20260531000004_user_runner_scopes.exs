defmodule Emisar.Repo.Migrations.UserRunnerScopes do
  use Ecto.Migration

  def change do
    # Per-membership runner allowlist. A membership with ZERO rows here
    # means "may touch every runner in the account" — current behavior,
    # so no backfill is needed for existing memberships.
    #
    # A membership with at least one row means "may only touch runners
    # matched by the union of these scopes":
    #
    #   scope_type = "group"  → scope_value matches runner.group
    #   scope_type = "runner" → scope_value matches runner.id (UUID)
    #
    # v1 is uniform per-membership (any role gates the same set of
    # runners). v2 may make this per-action — punt until needed.
    create table(:user_runner_scopes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :membership_id, references(:memberships, type: :binary_id, on_delete: :delete_all),
        null: false

      add :scope_type, :string, null: false
      add :scope_value, :string, null: false

      timestamps(updated_at: false)
    end

    create index(:user_runner_scopes, [:membership_id])

    create unique_index(:user_runner_scopes, [:membership_id, :scope_type, :scope_value],
             name: :user_runner_scopes_unique
           )

    create constraint(:user_runner_scopes, :user_runner_scopes_scope_type_check,
             check: "scope_type IN ('group', 'runner')"
           )
  end
end
