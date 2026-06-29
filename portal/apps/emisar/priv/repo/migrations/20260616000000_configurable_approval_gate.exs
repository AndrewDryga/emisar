defmodule Emisar.Repo.Migrations.ConfigurableApprovalGate do
  use Ecto.Migration

  def change do
    # One operator's vote on an approval request. Distinctness of approvers
    # is the (request_id, decider_id) unique index — the finalize check
    # counts DISTINCT approve votes, never a read-before-write.
    create table(:approval_decisions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :request_id, references(:approval_requests, type: :binary_id, on_delete: :delete_all),
        null: false

      add :decider_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :decision, :string, null: false
      add :decided_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:approval_decisions, [:request_id, :decider_id])
    create index(:approval_decisions, [:request_id])
    create index(:approval_decisions, [:account_id])

    # Snapshot the approval-gate posture onto the request at creation, so a
    # later policy edit can't change an in-flight request's bar. Defaults
    # reproduce single-approver, self-approval-allowed behavior.
    alter table(:approval_requests) do
      add :min_approvals, :integer, null: false, default: 1
      add :allow_self_approval, :boolean, null: false, default: true
    end
  end
end
