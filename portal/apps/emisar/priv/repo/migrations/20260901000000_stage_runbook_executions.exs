defmodule Emisar.Repo.Migrations.StageRunbookExecutions do
  use Ecto.Migration

  def up do
    alter table(:runbook_executions) do
      add :frozen_plan, :map, null: false, default: %{}
      add :inputs_raw, :binary
      add :inputs_sha256, :string
      add :sensitive_input_names, {:array, :string}, null: false, default: []
      add :completed_at, :utc_datetime_usec
      add :last_advanced_at, :utc_datetime_usec
      add :terminal_code, :string
      add :terminal_message, :string
    end

    create index(:runbook_executions, [:status, :last_advanced_at, :inserted_at],
             where: "status = 'active'",
             name: :runbook_executions_fair_recovery_index
           )

    create index(:runbook_executions, [:runbook_id, :inserted_at, :id],
             name: :runbook_executions_recent_by_runbook_index
           )

    create index(:runbook_executions, [:account_id, :status],
             where: "status = 'active'",
             name: :runbook_executions_active_by_account_index
           )

    create table(:runbook_execution_stages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :runbook_execution_id,
          references(:runbook_executions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :stage_id, :string, null: false
      add :position, :integer, null: false
      add :title, :string, null: false
      add :mode, :string, null: false
      add :max_parallel, :integer, null: false
      add :approval, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :terminal_code, :string
      add :terminal_message, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:runbook_execution_stages, [:runbook_execution_id, :position])
    create unique_index(:runbook_execution_stages, [:runbook_execution_id, :stage_id])
    create index(:runbook_execution_stages, [:account_id, :status])

    create table(:runbook_execution_items, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :runbook_execution_id,
          references(:runbook_executions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :runbook_execution_stage_id,
          references(:runbook_execution_stages, type: :binary_id, on_delete: :delete_all),
          null: false

      add :stage_position, :integer, null: false
      add :step_id, :string, null: false
      add :step_position, :integer, null: false
      add :runner_id, references(:runners, type: :binary_id, on_delete: :nilify_all)
      add :runner_ref, :string, null: false
      add :action_id, :string, null: false
      add :pack_ref, :string, null: false
      add :pack_hash, :string, null: false
      add :risk, :string
      add :action_contract, :map, null: false, default: %{}
      add :binding_plan, :map, null: false, default: %{}
      add :output_plan, {:array, :map}, null: false, default: []
      add :success_plan, {:array, :map}, null: false, default: []
      add :args_raw, :binary
      add :args_sha256, :string
      add :sensitive_arg_names, {:array, :string}, null: false, default: []
      add :wait, :map
      add :status, :string, null: false, default: "pending"
      add :attempt_count, :integer, null: false, default: 0
      add :wait_started_at, :utc_datetime_usec
      add :next_attempt_at, :utc_datetime_usec
      add :outputs, :map, null: false, default: %{}
      add :outputs_raw, :binary
      add :outputs_sha256, :string
      add :success_evidence, {:array, :map}, null: false, default: []
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :terminal_code, :string
      add :terminal_message, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :runbook_execution_items,
             [:runbook_execution_id, :step_id, :runner_ref],
             name: :runbook_execution_items_logical_identity_index
           )

    create index(:runbook_execution_items, [:account_id, :status])
    create index(:runbook_execution_items, [:runbook_execution_stage_id, :status])

    create index(:runbook_execution_items, [:status, :next_attempt_at],
             where: "status = 'waiting'",
             name: :runbook_execution_items_due_wait_index
           )

    alter table(:action_runs) do
      add :runbook_execution_item_id,
          references(:runbook_execution_items, type: :binary_id, on_delete: :delete_all)

      add :attempt_number, :integer
    end

    create unique_index(:action_runs, [:runbook_execution_item_id, :attempt_number],
             where: "runbook_execution_item_id IS NOT NULL",
             name: :action_runs_runbook_item_attempt_index
           )

    alter table(:approval_requests) do
      add :runbook_execution_stage_id,
          references(:runbook_execution_stages, type: :binary_id, on_delete: :delete_all)
    end

    execute "ALTER TABLE approval_requests ALTER COLUMN run_id DROP NOT NULL"
    drop unique_index(:approval_requests, [:run_id])

    create unique_index(:approval_requests, [:run_id],
             where: "run_id IS NOT NULL",
             name: :approval_requests_run_id_index
           )

    create unique_index(:approval_requests, [:runbook_execution_stage_id],
             where: "runbook_execution_stage_id IS NOT NULL",
             name: :approval_requests_runbook_stage_index
           )

    drop unique_index(:action_runs, [:runbook_execution_id, :runbook_step_id, :runner_id],
           name: :action_runs_execution_step_runner_index
         )

    alter table(:runbook_executions) do
      remove :work_list, {:array, :map}
    end

    create constraint(:runbook_executions, :runbook_executions_status_check,
             check: "status IN ('active', 'succeeded', 'halted', 'cancelled')"
           )

    create constraint(:runbook_execution_stages, :runbook_execution_stages_status_check,
             check:
               "status IN ('pending', 'awaiting_approval', 'active', 'succeeded', 'halted', 'cancelled')"
           )

    create constraint(:runbook_execution_stages, :runbook_execution_stages_mode_check,
             check: "mode IN ('sequential', 'parallel')"
           )

    create constraint(:runbook_execution_stages, :runbook_execution_stages_approval_check,
             check: "approval IN ('none', 'required')"
           )

    create constraint(
             :runbook_execution_stages,
             :runbook_execution_stages_max_parallel_check,
             check: "max_parallel >= 1 AND max_parallel <= 16"
           )

    create constraint(:runbook_execution_items, :runbook_execution_items_status_check,
             check:
               "status IN ('pending', 'running', 'waiting', 'succeeded', 'failed', 'cancelled')"
           )

    create constraint(
             :runbook_execution_items,
             :runbook_execution_items_attempt_count_check,
             check: "attempt_count >= 0 AND attempt_count <= 100"
           )

    create constraint(:runbook_execution_items, :runbook_execution_items_args_identity_check,
             check: "args_raw IS NULL OR args_sha256 IS NOT NULL"
           )

    create constraint(:runbook_execution_items, :runbook_execution_items_outputs_identity_check,
             check: "outputs_raw IS NULL OR outputs_sha256 IS NOT NULL"
           )

    create constraint(:action_runs, :action_runs_runbook_attempt_identity_check,
             check:
               "(runbook_execution_item_id IS NULL AND attempt_number IS NULL) OR " <>
                 "(runbook_execution_item_id IS NOT NULL AND attempt_number >= 1 AND runbook_execution_id IS NOT NULL)"
           )

    create constraint(:approval_requests, :approval_requests_exactly_one_target_check,
             check:
               "(run_id IS NOT NULL AND runbook_execution_stage_id IS NULL) OR " <>
                 "(run_id IS NULL AND runbook_execution_stage_id IS NOT NULL)"
           )
  end

  def down do
    drop constraint(:approval_requests, :approval_requests_exactly_one_target_check)
    drop constraint(:action_runs, :action_runs_runbook_attempt_identity_check)
    drop constraint(:runbook_execution_items, :runbook_execution_items_outputs_identity_check)
    drop constraint(:runbook_execution_items, :runbook_execution_items_args_identity_check)
    drop constraint(:runbook_execution_items, :runbook_execution_items_attempt_count_check)
    drop constraint(:runbook_execution_items, :runbook_execution_items_status_check)
    drop constraint(:runbook_execution_stages, :runbook_execution_stages_max_parallel_check)
    drop constraint(:runbook_execution_stages, :runbook_execution_stages_approval_check)
    drop constraint(:runbook_execution_stages, :runbook_execution_stages_mode_check)
    drop constraint(:runbook_execution_stages, :runbook_execution_stages_status_check)
    drop constraint(:runbook_executions, :runbook_executions_status_check)

    alter table(:runbook_executions) do
      add :work_list, {:array, :map}, null: false, default: []
    end

    create unique_index(:action_runs, [:runbook_execution_id, :runbook_step_id, :runner_id],
             where: "runbook_execution_id IS NOT NULL",
             name: :action_runs_execution_step_runner_index
           )

    drop index(:approval_requests, [:runbook_execution_stage_id],
           name: :approval_requests_runbook_stage_index
         )

    drop index(:approval_requests, [:run_id], name: :approval_requests_run_id_index)
    create unique_index(:approval_requests, [:run_id])
    execute "ALTER TABLE approval_requests ALTER COLUMN run_id SET NOT NULL"

    alter table(:approval_requests) do
      remove :runbook_execution_stage_id, :binary_id
    end

    drop index(:action_runs, [:runbook_execution_item_id, :attempt_number],
           name: :action_runs_runbook_item_attempt_index
         )

    alter table(:action_runs) do
      remove :attempt_number, :integer
      remove :runbook_execution_item_id, :binary_id
    end

    drop table(:runbook_execution_items)
    drop table(:runbook_execution_stages)

    drop index(:runbook_executions, [:runbook_id, :inserted_at, :id],
           name: :runbook_executions_recent_by_runbook_index
         )

    drop index(:runbook_executions, [:account_id, :status],
           name: :runbook_executions_active_by_account_index
         )

    drop index(:runbook_executions, [:status, :last_advanced_at, :inserted_at],
           name: :runbook_executions_fair_recovery_index
         )

    alter table(:runbook_executions) do
      remove :terminal_message, :string
      remove :terminal_code, :string
      remove :last_advanced_at, :utc_datetime_usec
      remove :completed_at, :utc_datetime_usec
      remove :sensitive_input_names, {:array, :string}
      remove :inputs_sha256, :string
      remove :inputs_raw, :binary
      remove :frozen_plan, :map
    end
  end
end
