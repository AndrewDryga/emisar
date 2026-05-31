defmodule Emisar.Runs.ActionRun do
  @moduledoc """
  A single action invocation against a runner. State machine:

      pending -> sent -> running -> {success, failed, error,
                                     validation_failed, unknown_action,
                                     cancelled, timed_out}

  Or:    pending -> awaiting_approval -> sent -> ...
  """

  use Emisar, :schema

  schema "action_runs" do
    field :request_id, :string
    field :action_id, :string
    field :runbook_step_id, :string

    field :api_key_id, Ecto.UUID
    field :source, :string, default: "operator"
    field :reason, :string

    field :args, :map, default: %{}
    field :args_sha256, :string
    field :opts, :map, default: %{}

    field :policy_decision, :string
    field :policy_reason, :string
    field :matched_rules, {:array, :string}, default: []

    field :requires_approval, :boolean, default: false
    field :approval_request_id, Ecto.UUID

    field :status, :string, default: "pending"
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

    belongs_to :account, Emisar.Accounts.Account
    belongs_to :runner, Emisar.Runners.Runner
    belongs_to :runbook, Emisar.Runbooks.Runbook
    belongs_to :requested_by, Emisar.Accounts.User
    belongs_to :policy, Emisar.Policies.Policy

    has_many :events, Emisar.Runs.RunEvent, foreign_key: :run_id

    timestamps()
  end

  def statuses, do: Emisar.Runs.ActionRun.Changeset.statuses()
  def sources, do: Emisar.Runs.ActionRun.Changeset.sources()

  @doc "Is `status` a terminal state?"
  def terminal?(status) when is_binary(status),
    do:
      status in ~w(success failed error validation_failed unknown_action cancelled timed_out)

  def terminal?(_), do: false
end
