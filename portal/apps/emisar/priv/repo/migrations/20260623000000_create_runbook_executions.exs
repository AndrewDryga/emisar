defmodule Emisar.Repo.Migrations.CreateRunbookExecutions do
  use Ecto.Migration

  def change do
    create table(:runbook_executions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :runbook_id, references(:runbooks, type: :binary_id, on_delete: :delete_all),
        null: false

      # The membership that initiated the run — the authorization anchor every
      # later wave revalidates (still active? each runner still in scope?)
      # instead of trusting a user-less continuation's nil bypass. Required: an
      # execution with no anchor can't be authorized, so it goes with its
      # membership (memberships soft-delete, so this cascade is only theoretical).
      add :initiating_membership_id,
          references(:memberships, type: :binary_id, on_delete: :delete_all),
          null: false

      # Attribution only — nullable + nilify like action_runs.requested_by_id, so
      # a hard-deleted user doesn't drop the execution's audit trail.
      add :requested_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      add :reason, :text, null: false
      # The frozen authorized work-list resolved at the first wave — the blast
      # radius later waves dispatch from, so group membership added mid-execution
      # is never picked up.
      add :work_list, {:array, :map}, null: false, default: []

      timestamps()
    end

    create index(:runbook_executions, [:account_id])
    create index(:runbook_executions, [:runbook_id])
  end
end
