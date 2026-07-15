defmodule Emisar.Runs.ActionRun do
  @moduledoc """
  A single action invocation against a runner. State machine:

      pending -> sent -> [running] -> terminal outcome
                            |
                            +-> cancelling -> terminal outcome

  Terminal outcomes are `success`, `failed`, `error`, `validation_failed`,
  `unknown_action`, `cancelled`, `timed_out`, and `refused`.

  Or:    pending -> pending_approval -> sent -> ...

  The policy gate can settle a run at creation: `pending -> denied` is a
  terminal outcome — the run is never sent to a runner.
  """
  use Emisar, :schema

  schema "action_runs" do
    field :request_id, :string
    field :action_id, :string
    field :runbook_step_id, :string
    # Groups the runs minted by one runbook invocation; the runbook engine
    # reads wave state (dispatched / in-flight / failed) off these rows. The
    # invocation's authorization anchor + frozen work-list live on the matching
    # `runbook_executions` row, not duplicated here.
    field :runbook_execution_id, Ecto.UUID

    field :api_key_id, Ecto.UUID
    # MCP / API caller supplies `Idempotency-Key`; a duplicate
    # `(api_key_id, idempotency_key)` returns the original run row
    # instead of dispatching a fresh one. Nil when the caller didn't
    # send the header (UI / runbook paths).
    field :idempotency_key, :string
    # Stable bridge-owned identity for one public MCP mutation. Fan-out creates
    # one row per runner under the same operation id; retries reuse those rows.
    field :operation_id, :string
    field :source, Ecto.Enum, values: [:operator, :runbook, :mcp, :scheduled], default: :operator
    field :reason, :string

    field :args, :map, default: %{}
    # Exact JSON token received for run_action.args. Policy and UI use `args`;
    # attestation hashing and runner delivery use these bytes without re-encoding.
    field :args_raw, :binary
    field :args_sha256, :string
    # Immutable content identity selected by the caller and checked against the
    # runner advertisement before the run is created.
    field :pack_ref, :string
    # Stable model-facing target identity snapshotted at authorization. History
    # must not depend on the runner row still existing or retaining its name.
    field :runner_ref, :string
    # The trusted pack hash snapshotted at authorization (MAJOR-5): the dispatch
    # ships THIS hash, so the runner verifies the exact bytes that were authorized
    # for this run. Nil for a pack-less action.
    field :expected_pack_hash, :string
    field :opts, :map, default: %{}
    # The client signature relayed from an MCP dispatch (%{"key_id", "sig",
    # "nonce", "issued_at"}); carried in the runner envelope so the runner can
    # verify it. Nil for portal-originated runs, which an enforcing runner refuses.
    field :attestation, :map
    # MCP clientInfo snapshot at dispatch time (e.g. %{"name" => "Claude
    # Code", "version" => "1.2.3"}); empty for non-MCP runs.
    field :client_info, :map, default: %{}
    # Self-reported MCP client metadata snapshotted at dispatch time — the
    # operator-configured key/value map (e.g. %{"asset_tag" => "LT-4417"}) an MCP
    # caller sends so its activity can be correlated with the customer's own
    # MDM/EDR/inventory in the audit log + SIEM export. UNTRUSTED, self-reported
    # enrichment, validated at the MCP boundary; empty for non-MCP runs. Never a
    # policy/approval/authorization input.
    field :mcp_client_metadata, :map, default: %{}
    # The dispatcher's source ip + user agent, snapshotted from the dispatch
    # request at create time so every run-lifecycle audit event can attribute the
    # action — even the terminal one logged from the runner socket, where there is
    # no inbound request. Nil for a system/engine-originated dispatch (no request).
    field :ip_address, :string
    field :user_agent, :string

    field :policy_decision, :string
    field :policy_reason, :string
    # Snapshot of `policies.vsn` at decision time. Lets us answer "this
    # run was approved under policy v5" without joining + trusting the
    # live policy row (which may have been edited since).
    field :policy_version, :integer
    field :matched_rules, {:array, :string}, default: []

    field :requires_approval, :boolean, default: false

    field :status, Ecto.Enum,
      values: [
        :pending,
        :pending_approval,
        :denied,
        :sent,
        :running,
        :cancelling,
        :success,
        :failed,
        :error,
        :validation_failed,
        :unknown_action,
        :cancelled,
        :timed_out,
        # The runner refused the dispatch on a pre-exec trust check (a bad/
        # missing/stale client signature, or a pack-hash mismatch) — distinct
        # from `:failed` (it ran and exited non-zero); the specific cause is in
        # `error_message`. See `Runs.@result_statuses`.
        :refused
      ],
      default: :pending

    field :queued_at, :utc_datetime_usec
    # Connection owner that accepted the dispatch. A timeout may replay only
    # while this generation still owns the runner identity; a different owner
    # makes the prior execution outcome unknown rather than safe to repeat.
    field :runner_connection_generation, :integer
    field :sent_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :cancelled_at, :utc_datetime_usec

    field :exit_code, :integer
    field :duration_ms, :integer
    field :timed_out, :boolean, default: false
    field :emitted_stdout_sha256, :string
    field :emitted_stderr_sha256, :string
    field :emitted_stdout_bytes, :integer
    field :emitted_stderr_bytes, :integer
    field :output_complete, :boolean, default: false
    field :stdout_truncated, :boolean, default: false
    field :stderr_truncated, :boolean, default: false
    field :event_id, :string
    field :reason_text, :string
    field :error_message, :string
    # The exact shell command the runner executed, with sensitive arg
    # values redacted by the runner. Set on the result transition.
    field :executed_command, :string

    # Durable per-run progress budget, incremented under the run's row lock on
    # each accepted progress chunk (`Runs.append_event`). Bounds a hostile
    # runner's distinct-seq event flood — see the append-event ceiling in Runs.
    field :progress_event_count, :integer, default: 0
    field :progress_byte_count, :integer, default: 0

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :runner, Emisar.Runners.Runner, where: [deleted_at: nil]
    belongs_to :runbook, Emisar.Runbooks.Runbook, where: [deleted_at: nil]
    belongs_to :requested_by, Emisar.Users.User, where: [deleted_at: nil]
    belongs_to :policy, Emisar.Policies.Policy, where: [deleted_at: nil]
    belongs_to :mcp_operation_record, Emisar.MCPOperations.Operation
    # api_key_id is already a field above; this reuses it so the run can
    # name its initiator (e.g. the "Claude Code" key) without a second FK.
    belongs_to :api_key, Emisar.ApiKeys.ApiKey,
      foreign_key: :api_key_id,
      define_field: false,
      where: [deleted_at: nil]

    has_many :events, Emisar.Runs.RunEvent, foreign_key: :run_id

    timestamps()
  end

  @terminal_statuses [
    :success,
    :failed,
    :error,
    :validation_failed,
    :unknown_action,
    :cancelled,
    :timed_out,
    :refused,
    :denied
  ]
  # Terminal NON-success — a run that settled badly. Exactly `@terminal_statuses`
  # minus `:success`, so a future terminal status is treated as a failure unless
  # it is explicitly a success; a renderer can't silently pass a new bad status
  # (e.g. `:refused`) off as a success.
  @failure_statuses @terminal_statuses -- [:success]

  @doc """
  Is `status` a terminal state? The single source of truth for "this run has
  settled" across the run engine, the runbook wave logic, the web, and MCP —
  never re-list these states elsewhere. `:denied` (policy refused at creation)
  and `:refused` (runner refused at dispatch) are terminal: the run won't
  progress, so it can't be cancelled or re-dispatched.
  """
  def terminal?(status) when is_atom(status), do: status in @terminal_statuses
  def terminal?(_), do: false

  @doc """
  The terminal NON-success statuses (`terminal?/1` minus `:success`) — the single
  source of truth for "this run failed", consumed by the MCP `is_error` render so
  a newly-added failure status can't slip through as a success.
  """
  def failure_statuses, do: @failure_statuses
  def failure?(status) when is_atom(status), do: status in @failure_statuses
  def failure?(_), do: false
end
