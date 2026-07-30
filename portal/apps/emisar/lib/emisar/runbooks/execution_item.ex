defmodule Emisar.Runbooks.ExecutionItem do
  @moduledoc "One frozen step and runner pair, including bounded observation attempts."
  use Emisar, :schema

  schema "runbook_execution_items" do
    field :stage_position, :integer
    field :step_id, :string
    field :step_position, :integer
    field :runner_ref, :string
    field :action_id, :string
    field :pack_ref, :string
    field :pack_hash, :string
    field :risk, :string
    field :policy_version, :integer
    field :policy_decision, :string
    field :policy_reason, :string
    field :matched_rules, {:array, :string}, default: []
    field :action_contract, :map, default: %{}
    field :binding_plan, :map, default: %{}
    field :output_plan, {:array, :map}, default: []
    field :success_plan, {:array, :map}, default: []
    field :args_raw, :binary
    field :args_sha256, :string
    field :sensitive_arg_names, {:array, :string}, default: []
    field :wait, :map

    field :status, Ecto.Enum,
      values: [:pending, :running, :waiting, :succeeded, :failed, :cancelled],
      default: :pending

    field :attempt_count, :integer, default: 0
    field :wait_started_at, :utc_datetime_usec
    field :next_attempt_at, :utc_datetime_usec
    field :outputs, :map, default: %{}
    field :outputs_raw, :binary
    field :outputs_sha256, :string
    field :success_evidence, {:array, :map}, default: []
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :terminal_code, :string
    field :terminal_message, :string

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :runbook_execution, Emisar.Runbooks.RunbookExecution
    belongs_to :runbook_execution_stage, Emisar.Runbooks.ExecutionStage
    belongs_to :runner, Emisar.Runners.Runner, where: [deleted_at: nil]
    belongs_to :policy, Emisar.Policies.Policy

    has_many :attempts, Emisar.Runs.ActionRun, foreign_key: :runbook_execution_item_id

    timestamps()
  end
end
