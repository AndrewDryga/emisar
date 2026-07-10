defmodule Emisar.Runs.ActionRun.Changeset do
  use Emisar, :changeset
  alias Emisar.Repo.Changeset, as: RepoChangeset
  alias Emisar.Runs.ActionRun

  @create_fields ~w[
    account_id runner_id request_id action_id args args_sha256 client_info
    mcp_session_id ip_address user_agent opts attestation reason source requested_by_id api_key_id idempotency_key
    runbook_id runbook_step_id runbook_execution_id expected_pack_hash
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
  # An honest attestation is ~300 bytes serialized (key_id + 128-hex sig + nonce
  # + timestamp); 8 KB is generous headroom while bounding the jsonb row + the
  # relayed wire envelope. The MCP boundary (normalize_attestation) already caps
  # each field; this backstops any other writer.
  @max_attestation_bytes 8_192
  # Runner-origin text can be large enough to explain a failure or show the
  # redacted command, but not unbounded. Plain string columns stay within the DB
  # string budget so malicious runner values fail as changeset errors first.
  @max_runner_text_length 16_384
  @max_db_string_length 255

  def create(attrs) do
    %ActionRun{}
    |> cast(attrs, @create_fields)
    |> validate_required([:account_id, :runner_id, :request_id, :action_id, :source])
    |> validate_length(:reason, max: @max_reason_length)
    |> RepoChangeset.validate_json_size(:args, @max_args_bytes)
    |> RepoChangeset.validate_json_size(:attestation, @max_attestation_bytes)
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
end
