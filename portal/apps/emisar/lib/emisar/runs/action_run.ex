defmodule Emisar.Runs.ActionRun do
  @moduledoc """
  A single action invocation against a runner. State machine:

      pending -> sent -> running -> {success, failed, error,
                                     validation_failed, unknown_action,
                                     cancelled, timed_out}

  Or:    pending -> pending_approval -> sent -> ...
  """
  use Emisar, :schema

  schema "action_runs" do
    field :request_id, :string
    field :action_id, :string
    field :runbook_step_id, :string
    # Groups the runs minted by one runbook invocation; the runbook engine
    # reads wave state (dispatched / in-flight / failed) off these rows.
    field :runbook_execution_id, Ecto.UUID
    # The invocation's dispatch descriptor: %{"target" => %{"runner_id" |
    # "group" => …}, "reason" => raw operator reason}. Same value on every
    # run of the execution so a continuation can rebuild the work list.
    field :runbook_dispatch, :map

    field :api_key_id, Ecto.UUID
    # MCP / API caller supplies `Idempotency-Key`; a duplicate
    # `(api_key_id, idempotency_key)` returns the original run row
    # instead of dispatching a fresh one. Nil when the caller didn't
    # send the header (UI / runbook paths).
    field :idempotency_key, :string
    field :source, Ecto.Enum, values: [:operator, :runbook, :mcp, :scheduled], default: :operator
    field :reason, :string

    field :args, :map, default: %{}
    field :args_sha256, :string
    field :opts, :map, default: %{}
    # The client signature relayed from an MCP dispatch (%{"key_id", "sig",
    # "nonce", "issued_at"}); carried in the runner envelope so the runner can
    # verify it. Nil for portal-originated runs, which an enforcing runner refuses.
    field :attestation, :map
    # MCP clientInfo snapshot at dispatch time (e.g. %{"name" => "Claude
    # Code", "version" => "1.2.3"}); empty for non-MCP runs.
    field :client_info, :map, default: %{}
    # MCP Streamable-HTTP session id (Mcp-Session-Id), for correlating the
    # runs from one session; nil for non-MCP runs.
    field :mcp_session_id, :string

    field :policy_decision, :string
    field :policy_reason, :string
    # Snapshot of `policies.vsn` at decision time. Lets us answer "this
    # run was approved under policy v5" without joining + trusting the
    # live policy row (which may have been edited since).
    field :policy_version, :integer
    field :matched_rules, {:array, :string}, default: []

    field :requires_approval, :boolean, default: false
    field :approval_request_id, Ecto.UUID

    field :status, Ecto.Enum,
      values: [
        :pending,
        :pending_approval,
        :denied,
        :sent,
        :running,
        :success,
        :failed,
        :error,
        :validation_failed,
        :unknown_action,
        :cancelled,
        :timed_out
      ],
      default: :pending

    field :queued_at, :utc_datetime_usec
    field :sent_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :cancelled_at, :utc_datetime_usec

    field :exit_code, :integer
    field :duration_ms, :integer
    field :timed_out, :boolean, default: false
    field :stdout_sha256, :string
    field :stderr_sha256, :string
    field :stdout_bytes, :integer
    field :stderr_bytes, :integer
    field :event_id, :string
    field :reason_text, :string
    field :error_message, :string
    # The exact shell command the runner executed, with sensitive arg
    # values redacted by the runner. Set on the result transition.
    field :executed_command, :string

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :runner, Emisar.Runners.Runner, where: [deleted_at: nil]
    belongs_to :runbook, Emisar.Runbooks.Runbook, where: [deleted_at: nil]
    belongs_to :requested_by, Emisar.Users.User, where: [deleted_at: nil]
    belongs_to :policy, Emisar.Policies.Policy, where: [deleted_at: nil]
    # api_key_id is already a field above; this reuses it so the run can
    # name its initiator (e.g. the "Claude Code" key) without a second FK.
    belongs_to :api_key, Emisar.ApiKeys.ApiKey,
      foreign_key: :api_key_id,
      define_field: false,
      where: [deleted_at: nil]

    has_many :events, Emisar.Runs.RunEvent, foreign_key: :run_id

    timestamps()
  end

  @doc "Is `status` a terminal state?"
  def terminal?(status) when is_atom(status),
    do:
      status in [
        :success,
        :failed,
        :error,
        :validation_failed,
        :unknown_action,
        :cancelled,
        :timed_out
      ]

  def terminal?(_), do: false
end
