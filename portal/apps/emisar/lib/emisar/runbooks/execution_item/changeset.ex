defmodule Emisar.Runbooks.ExecutionItem.Changeset do
  use Emisar, :changeset
  alias Emisar.Runbooks.ExecutionItem

  @create_fields ~w[
    id account_id runbook_execution_id runbook_execution_stage_id stage_position step_id
    step_position runner_id runner_ref action_id pack_ref pack_hash risk action_contract
    binding_plan output_plan success_plan args_raw args_sha256 sensitive_arg_names wait
  ]a
  @deferred_fields ~w[wait args_raw args_sha256]a

  def create(attrs) do
    %ExecutionItem{}
    |> cast(attrs, @create_fields)
    |> validate_required(@create_fields -- @deferred_fields)
    |> validate_length(:step_id, min: 1, max: 80)
    |> validate_length(:runner_ref, min: 1, max: 113)
    |> validate_length(:action_id, min: 1, max: 128)
    |> validate_length(:pack_ref, min: 1, max: 255)
    |> validate_length(:pack_hash, is: 71)
    |> validate_length(:args_sha256, is: 64)
    |> validate_number(:stage_position, greater_than_or_equal_to: 0, less_than: 16)
    |> validate_number(:step_position, greater_than_or_equal_to: 0, less_than: 32)
    |> unique_constraint([:runbook_execution_id, :step_id, :runner_ref],
      name: :runbook_execution_items_logical_identity_index
    )
    |> check_constraint(:status, name: :runbook_execution_items_status_check)
    |> check_constraint(:attempt_count, name: :runbook_execution_items_attempt_count_check)
    |> check_constraint(:args_raw, name: :runbook_execution_items_args_identity_check)
  end

  def start_attempt(%ExecutionItem{} = item, attempt_number, args_raw, args_sha256, now) do
    change(item,
      status: :running,
      attempt_count: attempt_number,
      args_raw: args_raw,
      args_sha256: args_sha256,
      started_at: item.started_at || now,
      next_attempt_at: nil
    )
    |> validate_number(:attempt_count, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_length(:args_sha256, is: 64)
    |> check_constraint(:args_raw, name: :runbook_execution_items_args_identity_check)
  end

  def wait(
        %ExecutionItem{} = item,
        outputs,
        outputs_raw,
        outputs_sha256,
        evidence,
        next_attempt_at,
        now
      ) do
    item
    |> change(
      status: :waiting,
      outputs: outputs,
      outputs_raw: outputs_raw,
      outputs_sha256: outputs_sha256,
      success_evidence: evidence,
      wait_started_at: item.wait_started_at || now,
      next_attempt_at: next_attempt_at,
      terminal_code: nil,
      terminal_message: nil
    )
    |> validate_outputs_identity()
  end

  def succeed(%ExecutionItem{} = item, outputs, outputs_raw, outputs_sha256, evidence, now) do
    item
    |> change(
      status: :succeeded,
      outputs: outputs,
      outputs_raw: outputs_raw,
      outputs_sha256: outputs_sha256,
      success_evidence: evidence,
      finished_at: now,
      next_attempt_at: nil,
      terminal_code: nil,
      terminal_message: nil
    )
    |> validate_outputs_identity()
  end

  def fail(
        %ExecutionItem{} = item,
        code,
        message,
        outputs,
        outputs_raw,
        outputs_sha256,
        evidence,
        now
      ) do
    change(item,
      status: :failed,
      outputs: outputs,
      outputs_raw: outputs_raw,
      outputs_sha256: outputs_sha256,
      success_evidence: evidence,
      finished_at: now,
      next_attempt_at: nil,
      terminal_code: code,
      terminal_message: message
    )
    |> validate_terminal()
    |> validate_outputs_identity()
  end

  def cancel(%ExecutionItem{} = item, now) do
    change(item,
      status: :cancelled,
      finished_at: now,
      next_attempt_at: nil,
      terminal_code: "cancelled",
      terminal_message: "Item was cancelled."
    )
  end

  def scrub_raw_payloads(%ExecutionItem{} = item) do
    change(item, args_raw: nil, outputs_raw: nil)
    |> check_constraint(:args_raw, name: :runbook_execution_items_args_identity_check)
    |> check_constraint(:outputs_raw, name: :runbook_execution_items_outputs_identity_check)
  end

  defp validate_terminal(changeset) do
    changeset
    |> validate_length(:terminal_code, min: 1, max: 80)
    |> validate_length(:terminal_message, max: 1_024)
  end

  defp validate_outputs_identity(changeset) do
    changeset
    |> validate_length(:outputs_sha256, is: 64)
    |> check_constraint(:outputs_raw, name: :runbook_execution_items_outputs_identity_check)
  end
end
