defmodule Emisar.Repo.Migrations.AddCompositeTenantRunnerFks do
  use Ecto.Migration

  # DB-level defense in depth: the single-column runner FKs let a raw-SQL
  # writer point a child row at another account's runner. The composite
  # (account_id, runner_id) FK makes that unrepresentable. Each replacement
  # keeps the constraint name Ecto infers for :runner_id so changeset
  # foreign_key_constraint error mapping is unchanged, and keeps ON DELETE
  # CASCADE. A NULL runner_id stays unenforced (MATCH SIMPLE), matching the
  # nullable single-column FK it replaces.

  def up do
    create unique_index(:runners, [:account_id, :id])

    drop constraint(:action_runs, "action_runs_runner_id_fkey")

    execute """
    ALTER TABLE action_runs
    ADD CONSTRAINT action_runs_runner_id_fkey
    FOREIGN KEY (account_id, runner_id)
    REFERENCES runners (account_id, id) ON DELETE CASCADE
    """

    drop constraint(:catalog_runner_actions, "catalog_runner_actions_runner_id_fkey")

    execute """
    ALTER TABLE catalog_runner_actions
    ADD CONSTRAINT catalog_runner_actions_runner_id_fkey
    FOREIGN KEY (account_id, runner_id)
    REFERENCES runners (account_id, id) ON DELETE CASCADE
    """
  end

  def down do
    drop constraint(:catalog_runner_actions, "catalog_runner_actions_runner_id_fkey")

    execute """
    ALTER TABLE catalog_runner_actions
    ADD CONSTRAINT catalog_runner_actions_runner_id_fkey
    FOREIGN KEY (runner_id) REFERENCES runners (id) ON DELETE CASCADE
    """

    drop constraint(:action_runs, "action_runs_runner_id_fkey")

    execute """
    ALTER TABLE action_runs
    ADD CONSTRAINT action_runs_runner_id_fkey
    FOREIGN KEY (runner_id) REFERENCES runners (id) ON DELETE CASCADE
    """

    drop index(:runners, [:account_id, :id])
  end
end
