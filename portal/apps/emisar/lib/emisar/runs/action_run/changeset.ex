defmodule Emisar.Runs.ActionRun.Changeset do
  use Emisar, :changeset
  alias Emisar.Runs.ActionRun

  @statuses ~w(
    pending awaiting_approval pending_approval denied sent running
    success failed error validation_failed unknown_action cancelled timed_out
  )
  @sources ~w(operator runbook mcp scheduled)

  @create_fields ~w[
    account_id runner_id request_id action_id args args_sha256
    opts reason source requested_by_id api_key_id runbook_id
    runbook_step_id policy_id policy_decision policy_reason
    matched_rules requires_approval status queued_at
  ]a

  @transition_fields ~w[
    sent_at started_at finished_at cancelled_at
    exit_code duration_ms timed_out
    stdout_sha256 stderr_sha256 stdout_bytes stderr_bytes
    event_id reason_text error_message
  ]a

  def create(attrs) do
    %ActionRun{}
    |> cast(attrs, @create_fields)
    |> validate_required([:account_id, :runner_id, :request_id, :action_id, :source])
    |> validate_inclusion(:source, @sources)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:account_id, :request_id])
  end

  def transition(%ActionRun{} = run, status, attrs \\ %{}) do
    run
    |> cast(attrs, @transition_fields)
    |> put_change(:status, to_string(status))
    |> validate_inclusion(:status, @statuses)
  end

  def statuses, do: @statuses
  def sources, do: @sources
end
