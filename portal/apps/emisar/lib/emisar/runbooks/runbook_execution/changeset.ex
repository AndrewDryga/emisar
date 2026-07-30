defmodule Emisar.Runbooks.RunbookExecution.Changeset do
  use Emisar, :changeset
  alias Emisar.Runbooks.RunbookExecution

  @fields ~w[
    id account_id runbook_id initiating_membership_id requested_by_id api_key_id
    operation_id mcp_operation_record_id reason frozen_plan inputs_raw inputs_sha256
    sensitive_input_names
  ]a

  def create(attrs) do
    %RunbookExecution{}
    |> cast(attrs, @fields)
    # `requested_by_id` is attribution-only and DB-nullable: an MCP-initiated
    # execution has an API-key actor, not a user, so it's nil there (audit
    # records the api_key actor, and `initiating_membership_id` is the real
    # authorization anchor). A user-initiated execution still sets it.
    |> validate_required([
      :id,
      :account_id,
      :runbook_id,
      :initiating_membership_id,
      :reason,
      :frozen_plan,
      :inputs_raw,
      :inputs_sha256
    ])
    |> validate_length(:reason, min: 1, max: 4_096)
    |> validate_length(:inputs_sha256, is: 64)
    |> unique_constraint(:mcp_operation_record_id,
      name: :runbook_executions_mcp_operation_index
    )
  end

  def succeed(%RunbookExecution{} = execution, now) do
    change(execution,
      status: :succeeded,
      completed_at: now,
      terminal_code: nil,
      terminal_message: nil
    )
  end

  def halt(%RunbookExecution{} = execution, code, message, now) do
    change(execution,
      status: :halted,
      halted_at: now,
      completed_at: now,
      terminal_code: code,
      terminal_message: message
    )
    |> validate_length(:terminal_code, min: 1, max: 80)
    |> validate_length(:terminal_message, max: 1_024)
  end

  def cancel(%RunbookExecution{} = execution, now) do
    change(execution,
      status: :cancelled,
      halted_at: now,
      completed_at: now,
      terminal_code: "cancelled",
      terminal_message: "Execution was cancelled."
    )
  end

  def mark_advanced(%RunbookExecution{} = execution, now),
    do: change(execution, last_advanced_at: now)

  def scrub_raw_inputs(%RunbookExecution{} = execution),
    do: change(execution, inputs_raw: nil)
end
