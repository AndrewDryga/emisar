defmodule Emisar.Repo.Migrations.ApproveWholeRunbookExecutions do
  use Ecto.Migration

  def up do
    drop constraint(:approval_requests, :approval_requests_exactly_one_target_check)

    drop index(:approval_requests, [:runbook_execution_stage_id],
           name: :approval_requests_runbook_stage_index
         )

    execute("DELETE FROM approval_requests WHERE runbook_execution_stage_id IS NOT NULL")
    execute("DELETE FROM runbook_executions")

    alter table(:approval_requests) do
      add :runbook_execution_id,
          references(:runbook_executions, type: :binary_id, on_delete: :delete_all)

      remove :runbook_execution_stage_id, :binary_id
    end

    create unique_index(:approval_requests, [:runbook_execution_id],
             where: "runbook_execution_id IS NOT NULL",
             name: :approval_requests_runbook_execution_index
           )

    create constraint(:approval_requests, :approval_requests_exactly_one_target_check,
             check:
               "(run_id IS NOT NULL AND runbook_execution_id IS NULL) OR " <>
                 "(run_id IS NULL AND runbook_execution_id IS NOT NULL)"
           )

    drop constraint(:runbook_executions, :runbook_executions_status_check)

    create constraint(:runbook_executions, :runbook_executions_status_check,
             check: "status IN ('pending_approval', 'active', 'succeeded', 'halted', 'cancelled')"
           )

    drop constraint(:runbook_execution_stages, :runbook_execution_stages_status_check)
    drop constraint(:runbook_execution_stages, :runbook_execution_stages_approval_check)

    alter table(:runbook_execution_stages) do
      remove :approval, :string
    end

    create constraint(:runbook_execution_stages, :runbook_execution_stages_status_check,
             check: "status IN ('pending', 'active', 'succeeded', 'halted', 'cancelled')"
           )

    alter table(:runbook_execution_items) do
      add :policy_id, references(:policies, type: :binary_id, on_delete: :nothing), null: false
      add :policy_version, :integer, null: false
      add :policy_decision, :string, null: false
      add :policy_reason, :string, null: false
      add :matched_rules, {:array, :string}, null: false, default: []
    end

    create constraint(:runbook_execution_items, :runbook_execution_items_policy_version_check,
             check: "policy_version >= 1"
           )

    create constraint(:runbook_execution_items, :runbook_execution_items_policy_decision_check,
             check: "policy_decision IN ('allow', 'require_approval')"
           )
  end

  def down do
    drop constraint(:runbook_execution_items, :runbook_execution_items_policy_decision_check)
    drop constraint(:runbook_execution_items, :runbook_execution_items_policy_version_check)

    alter table(:runbook_execution_items) do
      remove :matched_rules, {:array, :string}
      remove :policy_reason, :string
      remove :policy_decision, :string
      remove :policy_version, :integer
      remove :policy_id, :binary_id
    end

    drop constraint(:runbook_execution_stages, :runbook_execution_stages_status_check)

    alter table(:runbook_execution_stages) do
      add :approval, :string, null: false, default: "none"
    end

    create constraint(:runbook_execution_stages, :runbook_execution_stages_status_check,
             check:
               "status IN ('pending', 'awaiting_approval', 'active', 'succeeded', 'halted', 'cancelled')"
           )

    create constraint(:runbook_execution_stages, :runbook_execution_stages_approval_check,
             check: "approval IN ('none', 'required')"
           )

    execute("DELETE FROM runbook_executions WHERE status = 'pending_approval'")

    drop constraint(:runbook_executions, :runbook_executions_status_check)

    create constraint(:runbook_executions, :runbook_executions_status_check,
             check: "status IN ('active', 'succeeded', 'halted', 'cancelled')"
           )

    drop constraint(:approval_requests, :approval_requests_exactly_one_target_check)

    drop index(:approval_requests, [:runbook_execution_id],
           name: :approval_requests_runbook_execution_index
         )

    alter table(:approval_requests) do
      add :runbook_execution_stage_id,
          references(:runbook_execution_stages, type: :binary_id, on_delete: :delete_all)

      remove :runbook_execution_id, :binary_id
    end

    create unique_index(:approval_requests, [:runbook_execution_stage_id],
             where: "runbook_execution_stage_id IS NOT NULL",
             name: :approval_requests_runbook_stage_index
           )

    create constraint(:approval_requests, :approval_requests_exactly_one_target_check,
             check:
               "(run_id IS NOT NULL AND runbook_execution_stage_id IS NULL) OR " <>
                 "(run_id IS NULL AND runbook_execution_stage_id IS NOT NULL)"
           )
  end
end
