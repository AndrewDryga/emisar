defmodule Emisar.Runs.ActionRun.Changeset do
  use Emisar, :changeset
  alias Emisar.Crypto
  alias Emisar.Repo.Changeset, as: RepoChangeset
  alias Emisar.Runs.ActionRun

  @create_fields ~w[
    account_id runner_id request_id action_id args_raw args_sha256 sensitive_arg_names client_info mcp_client_metadata
    ip_address user_agent opts attestation reason source requested_by_id api_key_id initiating_membership_id
    operation_id mcp_operation_record_id pack_ref runner_ref runbook_id runbook_step_id runbook_execution_id expected_pack_hash
    structured_output_expected output_schema_snapshot
    policy_id policy_version policy_decision
    policy_reason matched_rules requires_approval status queued_at
  ]a

  @transition_fields ~w[
    runner_connection_generation queued_at sent_at started_at finished_at cancelled_at
    exit_code duration_ms timed_out
    emitted_stdout_sha256 emitted_stderr_sha256 emitted_stdout_bytes emitted_stderr_bytes
    output_complete stdout_truncated stderr_truncated event_id local_audit_failed reason_text error_message
    executed_command executed_command_truncated
    structured_output
  ]a

  # Generous caps — well above any real action's args (the largest, the shell
  # pack's `script`, is 64 KB) — but they bound a hostile MCP client that would
  # otherwise write a multi-MB row and fan it onto the runner's PubSub topic.
  # The runner re-validates args per-spec at execution, but the cloud-side cost
  # is paid before that rejection.
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
  @max_executed_command_bytes 16_384
  @max_db_string_length 255
  @max_action_args_bytes 32_768
  @max_structured_output_bytes 8_192
  @min_db_integer -2_147_483_648
  @max_db_integer 2_147_483_647
  @max_db_bigint 9_223_372_036_854_775_807
  @max_run_opt_value 9_223_372_036_854_775_807
  @run_opt_keys ~w(timeout max_stdout_bytes max_stderr_bytes)

  def create(attrs) do
    attrs = Map.put(attrs, :args_raw, action_args_raw(attrs))

    %ActionRun{}
    |> cast(attrs, @create_fields)
    |> validate_required([:account_id, :runner_id, :request_id, :action_id, :source, :args_raw])
    |> validate_change(:request_id, &validate_request_id/2)
    |> validate_length(:reason, max: @max_reason_length)
    |> validate_length(:operation_id, max: @max_db_string_length)
    |> validate_length(:pack_ref, max: @max_db_string_length)
    |> validate_length(:runner_ref, max: 113)
    |> validate_action_args_raw()
    |> validate_run_opts()
    |> validate_signed_run_opts()
    |> RepoChangeset.validate_json_size(:attestation, @max_attestation_bytes)
    |> RepoChangeset.validate_json_size(:mcp_client_metadata, @max_client_metadata_bytes)
    |> RepoChangeset.validate_json_size(:output_schema_snapshot, @max_structured_output_bytes)
    |> validate_output_schema_snapshot()
    |> unique_constraint([:account_id, :request_id])
    |> unique_constraint([:mcp_operation_record_id, :runner_id],
      name: :action_runs_mcp_operation_runner_index
    )
    |> unique_constraint([:runbook_execution_id, :runbook_step_id, :runner_id],
      name: :action_runs_execution_step_runner_index
    )
  end

  defp validate_output_schema_snapshot(changeset) do
    expected? = get_field(changeset, :structured_output_expected)
    snapshot = get_field(changeset, :output_schema_snapshot)

    cond do
      expected? and is_nil(snapshot) ->
        add_error(changeset, :output_schema_snapshot, "is required for typed output")

      expected? and not Emisar.OutputSchema.valid?(snapshot) ->
        add_error(changeset, :output_schema_snapshot, "must be a valid output schema")

      not expected? and not is_nil(snapshot) ->
        add_error(changeset, :output_schema_snapshot, "must be absent for untyped output")

      true ->
        changeset
    end
  end

  defp validate_request_id(:request_id, request_id) do
    if Crypto.valid_run_request_id?(request_id),
      do: [],
      else: [request_id: "must be a canonical run request id"]
  end

  defp action_args_raw(attrs) do
    case Map.get(attrs, :args_raw) || Map.get(attrs, "args_raw") do
      raw when is_binary(raw) -> raw
      _ -> Jason.encode!(Map.get(attrs, :args) || Map.get(attrs, "args") || %{})
    end
  end

  defp validate_action_args_raw(changeset) do
    validate_change(changeset, :args_raw, fn :args_raw, raw ->
      cond do
        byte_size(raw) > @max_action_args_bytes ->
          [args_raw: "is too large (max #{@max_action_args_bytes} bytes)"]

        match?({:ok, %{}}, Jason.decode(raw, floats: :decimals)) ->
          []

        true ->
          [args_raw: "must be a JSON object"]
      end
    end)
  end

  defp validate_run_opts(changeset) do
    validate_change(changeset, :opts, fn :opts, opts ->
      cond do
        not is_map(opts) ->
          [opts: "must be an object"]

        Enum.any?(Map.keys(opts), &(&1 not in @run_opt_keys)) ->
          [opts: "supports only timeout, max_stdout_bytes, and max_stderr_bytes"]

        Enum.any?(Map.values(opts), &invalid_run_opt?/1) ->
          [opts: "values must be positive integers within the signed 64-bit range"]

        true ->
          []
      end
    end)
  end

  defp invalid_run_opt?(value) do
    not (is_integer(value) and value > 0 and value <= @max_run_opt_value)
  end

  defp validate_signed_run_opts(changeset) do
    opts = get_field(changeset, :opts)

    if not is_nil(get_field(changeset, :attestation)) and is_map(opts) and map_size(opts) > 0 do
      add_error(changeset, :opts, "must be empty for an attested run")
    else
      changeset
    end
  end

  def transition(%ActionRun{} = run, status, attrs \\ %{}) when is_atom(status) do
    run
    |> cast(attrs, @transition_fields)
    |> put_change(:status, status)
    |> validate_length(:reason_text, max: @max_reason_length)
    |> validate_length(:error_message, max: @max_runner_text_length)
    |> validate_change(:executed_command, &validate_executed_command/2)
    |> validate_length(:emitted_stdout_sha256, max: @max_db_string_length)
    |> validate_length(:emitted_stderr_sha256, max: @max_db_string_length)
    |> validate_length(:event_id, max: @max_db_string_length)
    |> validate_structured_output()
    |> validate_number(:exit_code,
      greater_than_or_equal_to: @min_db_integer,
      less_than_or_equal_to: @max_db_integer
    )
    |> validate_number(:emitted_stdout_bytes,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: @max_db_bigint
    )
    |> validate_number(:emitted_stderr_bytes,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: @max_db_bigint
    )
    |> validate_number(:duration_ms,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: @max_db_integer
    )
  end

  defp validate_structured_output(changeset) do
    validate_change(changeset, :structured_output, fn :structured_output, output ->
      with true <- is_map(output),
           :ok <- Emisar.JSONValue.validate(output, max_depth: 16, max_nodes: 1_024),
           {:ok, encoded} <- Jason.encode(output),
           true <- byte_size(encoded) <= @max_structured_output_bytes do
        []
      else
        _other -> [structured_output: "must be a bounded JSON object"]
      end
    end)
  end

  defp validate_executed_command(:executed_command, command) do
    if byte_size(command) <= @max_executed_command_bytes,
      do: [],
      else: [executed_command: "is too large (max #{@max_executed_command_bytes} bytes)"]
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
