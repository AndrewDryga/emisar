defmodule Emisar.Runbooks.ExecutionStage.Changeset do
  use Emisar, :changeset
  alias Emisar.Runbooks.ExecutionStage

  @create_fields ~w[
    id account_id runbook_execution_id stage_id position title mode max_parallel status
  ]a

  def create(attrs) do
    %ExecutionStage{}
    |> cast(attrs, @create_fields)
    |> validate_required(@create_fields)
    |> validate_length(:stage_id, min: 1, max: 80)
    |> validate_length(:title, min: 1, max: 80)
    |> validate_number(:position, greater_than_or_equal_to: 0, less_than: 16)
    |> validate_number(:max_parallel, greater_than_or_equal_to: 1, less_than_or_equal_to: 16)
    |> unique_constraint([:runbook_execution_id, :position])
    |> unique_constraint([:runbook_execution_id, :stage_id])
    |> check_constraint(:status, name: :runbook_execution_stages_status_check)
    |> check_constraint(:mode, name: :runbook_execution_stages_mode_check)
    |> check_constraint(:max_parallel, name: :runbook_execution_stages_max_parallel_check)
  end

  def activate(%ExecutionStage{} = stage, now),
    do: change(stage, status: :active, started_at: stage.started_at || now)

  def succeed(%ExecutionStage{} = stage, now) do
    change(stage,
      status: :succeeded,
      finished_at: now,
      terminal_code: nil,
      terminal_message: nil
    )
  end

  def halt(%ExecutionStage{} = stage, code, message, now) do
    change(stage,
      status: :halted,
      finished_at: now,
      terminal_code: code,
      terminal_message: message
    )
    |> validate_terminal()
  end

  def cancel(%ExecutionStage{} = stage, now) do
    change(stage,
      status: :cancelled,
      finished_at: now,
      terminal_code: "cancelled",
      terminal_message: "Stage was cancelled."
    )
  end

  defp validate_terminal(changeset) do
    changeset
    |> validate_length(:terminal_code, min: 1, max: 80)
    |> validate_length(:terminal_message, max: 1_024)
  end
end
