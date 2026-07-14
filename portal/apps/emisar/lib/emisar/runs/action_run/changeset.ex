defmodule Emisar.Runs.ActionRun.Changeset do
  use Emisar, :changeset
  alias Emisar.Repo.Changeset, as: RepoChangeset
  alias Emisar.Runs.ActionRun

  @create_fields ~w[
    account_id runner_id request_id action_id args args_raw args_sha256 client_info mcp_client_metadata
    mcp_session_id ip_address user_agent opts attestation reason source requested_by_id api_key_id idempotency_key
    operation_id mcp_operation_record_id pack_ref runner_ref runbook_id runbook_step_id runbook_execution_id expected_pack_hash
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
  # pack's `script`, is 64 KB) — but they bound a hostile MCP client that would
  # otherwise write a multi-MB row and fan it onto the runner's PubSub topic.
  # The runner re-validates args per-spec at execution, but the cloud-side cost
  # is paid before that rejection.
  @max_args_bytes 262_144
  @max_reason_length 255
  # A normal v2 attestation is comfortably below 2 KB (cert, signature, nonce,
  # timestamp, and up to 16 runner ids); 8 KB is generous headroom while bounding
  # the jsonb row + relayed wire envelope. The MCP boundary already caps every
  # known field; this backstops any other writer.
  @max_attestation_bytes 8_192
  # Self-reported MCP client metadata is bounded at the MCP boundary (≤10 keys,
  # keys ≤128 / values ≤512 chars ≈ 6 KB); 8 KB backstops any other writer.
  @max_client_metadata_bytes 8_192
  # Runner-origin text can be large enough to explain a failure or show the
  # redacted command, but not unbounded. Plain string columns stay within the DB
  # string budget so malicious runner values fail as changeset errors first.
  @max_runner_text_length 16_384
  @max_db_string_length 255
  @max_action_args_bytes 32_768

  def create(attrs) do
    %ActionRun{}
    |> cast(attrs, @create_fields)
    |> validate_required([:account_id, :runner_id, :request_id, :action_id, :source])
    |> validate_length(:reason, max: @max_reason_length)
    |> validate_length(:mcp_session_id, max: @max_db_string_length)
    |> validate_length(:operation_id, max: @max_db_string_length)
    |> validate_length(:pack_ref, max: @max_db_string_length)
    |> validate_length(:runner_ref, max: 113)
    |> validate_length(:args_raw, max: @max_action_args_bytes)
    |> RepoChangeset.validate_json_size(:args, @max_args_bytes)
    |> RepoChangeset.validate_json_size(:attestation, @max_attestation_bytes)
    |> RepoChangeset.validate_json_size(:mcp_client_metadata, @max_client_metadata_bytes)
    |> unique_constraint([:account_id, :request_id])
    |> unique_constraint([:api_key_id, :idempotency_key],
      name: :action_runs_api_key_idempotency_key_index
    )
    |> unique_constraint([:mcp_operation_record_id, :runner_id],
      name: :action_runs_mcp_operation_runner_index
    )
    |> unique_constraint([:runbook_execution_id, :runbook_step_id, :runner_id],
      name: :action_runs_execution_step_runner_index
    )
  end

  def transition(%ActionRun{} = run, status, attrs \\ %{}) when is_atom(status) do
    run
    |> cast(attrs, @transition_fields)
    |> put_change(:status, status)
    |> validate_length(:reason_text, max: @max_reason_length)
    |> validate_length(:error_message, max: @max_runner_text_length)
    |> validate_length(:executed_command, max: @max_runner_text_length)
    |> validate_length(:stdout_sha256, max: @max_db_string_length)
    |> validate_length(:stderr_sha256, max: @max_db_string_length)
    |> validate_length(:event_id, max: @max_db_string_length)
    |> validate_number(:stdout_bytes, greater_than_or_equal_to: 0)
    |> validate_number(:stderr_bytes, greater_than_or_equal_to: 0)
    |> validate_number(:duration_ms, greater_than_or_equal_to: 0)
  end

  @doc "Release an approval-gated run into a fresh dispatch window."
  def release_pending_approval(%ActionRun{} = run) do
    change(run, status: :pending, queued_at: DateTime.utc_now())
  end

  @doc """
  Charge one accepted progress chunk (`event_bytes` serialized payload bytes)
  against the run's durable budget. Called on the LOCKED run inside
  `Runs.append_event`, so the read-modify-write can't lose a concurrent bump.
  """
  def record_progress(%ActionRun{} = run, event_bytes) when is_integer(event_bytes) do
    change(run,
      progress_event_count: run.progress_event_count + 1,
      progress_byte_count: run.progress_byte_count + event_bytes
    )
  end
end
