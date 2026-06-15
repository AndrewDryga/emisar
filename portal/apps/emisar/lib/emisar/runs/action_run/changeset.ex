defmodule Emisar.Runs.ActionRun.Changeset do
  use Emisar, :changeset
  alias Emisar.Runs.ActionRun

  @create_fields ~w[
    account_id runner_id request_id action_id args args_sha256 client_info
    mcp_session_id opts reason source requested_by_id api_key_id idempotency_key
    runbook_id runbook_step_id runbook_execution_id runbook_dispatch
    policy_id policy_version policy_decision
    policy_reason matched_rules requires_approval status queued_at
  ]a

  @transition_fields ~w[
    sent_at started_at finished_at cancelled_at
    exit_code duration_ms timed_out
    stdout_sha256 stderr_sha256 stdout_bytes stderr_bytes
    event_id reason_text error_message executed_command
  ]a

  # Generous caps — well above any real action's args (the largest, the shell
  # pack's `script`, is 64 KB) or an operator's "why" reason — but they bound a
  # hostile MCP client that would otherwise write a multi-MB row and fan it onto
  # the runner's PubSub topic. The runner re-validates args per-spec at
  # execution, but the cloud-side cost is paid before that rejection.
  @max_args_bytes 262_144
  @max_reason_length 4_096

  def create(attrs) do
    %ActionRun{}
    |> cast(attrs, @create_fields)
    |> validate_required([:account_id, :runner_id, :request_id, :action_id, :source])
    |> validate_length(:reason, max: @max_reason_length)
    |> validate_args_size()
    |> unique_constraint([:account_id, :request_id])
    |> unique_constraint([:api_key_id, :idempotency_key],
      name: :action_runs_api_key_idempotency_key_index
    )
    |> unique_constraint([:runbook_execution_id, :runbook_step_id, :runner_id],
      name: :action_runs_execution_step_runner_index
    )
  end

  def transition(%ActionRun{} = run, status, attrs \\ %{}) when is_atom(status) do
    run
    |> cast(attrs, @transition_fields)
    |> put_change(:status, status)
  end

  defp validate_args_size(changeset) do
    case get_change(changeset, :args) do
      args when is_map(args) ->
        case Jason.encode(args) do
          {:ok, json} when byte_size(json) > @max_args_bytes ->
            add_error(changeset, :args, "is too large (max #{@max_args_bytes} bytes serialized)")

          _ ->
            changeset
        end

      _ ->
        changeset
    end
  end
end
