defmodule Emisar.Repo.Migrations.PolicyScopes do
  use Ecto.Migration

  # Policies can now be scoped to a single runner or a runner group, not
  # just the whole account. `scope_type` / `scope_value` identify the scope:
  #
  #   * "account" + ""           → the account-wide default (every existing row)
  #   * "runner"  + <runner_id>  → overrides for that one runner
  #   * "group"   + <group name> → overrides for that runner group
  #
  # Dispatch resolves the MOST SPECIFIC policy (runner > group > account) and
  # evaluates it wholesale. The column defaults backfill existing rows to the
  # account scope, so this is a no-data-loss additive migration.
  #
  # One-policy-per-account becomes one-policy-per-(account, scope): swap the
  # partial unique index on (account_id) for (account_id, scope_type,
  # scope_value), still `WHERE deleted_at IS NULL` so soft-deleted rows don't
  # reserve a scope.
  @partial "deleted_at IS NULL"

  def up do
    alter table(:policies) do
      add :scope_type, :string, null: false, default: "account"
      add :scope_value, :string, null: false, default: ""
    end

    drop_if_exists index(:policies, [:account_id])
    create unique_index(:policies, [:account_id, :scope_type, :scope_value], where: @partial)
  end

  def down do
    # Rolling back assumes at most one policy per account again — delete any
    # runner/group-scoped policies first or this unique index will conflict.
    drop_if_exists index(:policies, [:account_id, :scope_type, :scope_value])
    create unique_index(:policies, [:account_id], where: @partial)

    alter table(:policies) do
      remove :scope_value
      remove :scope_type
    end
  end
end
