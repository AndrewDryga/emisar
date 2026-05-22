defmodule Emisar.Runs.ActionRun do
  @moduledoc """
  A single action invocation against an runner. State machine:

      pending -> sent -> running -> {success, failed, error,
                                     validation_failed, unknown_action,
                                     cancelled, timed_out}

  Or:    pending -> awaiting_approval -> sent -> ...
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(
    pending awaiting_approval pending_approval denied sent running
    success failed error validation_failed unknown_action cancelled timed_out
  )
  @sources ~w(operator runbook mcp scheduled)

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

    field :policy_version, :integer
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

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(run, attrs) do
    run
    |> cast(attrs, [
      :account_id, :runner_id, :request_id, :action_id, :args, :args_sha256,
      :opts, :reason, :source, :requested_by_id, :api_key_id, :runbook_id,
      :runbook_step_id, :policy_id, :policy_version, :policy_decision,
      :policy_reason, :matched_rules, :requires_approval, :status, :queued_at
    ])
    |> validate_required([:account_id, :runner_id, :request_id, :action_id, :source])
    |> validate_inclusion(:source, @sources)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:account_id, :request_id])
  end

  def transition_changeset(run, status, attrs \\ %{}) do
    run
    |> cast(attrs, [
      :sent_at, :started_at, :finished_at, :cancelled_at,
      :exit_code, :duration_ms, :timed_out,
      :stdout_sha256, :stderr_sha256, :stdout_bytes, :stderr_bytes,
      :event_id, :reason_text, :error_message
    ])
    |> put_change(:status, to_string(status))
    |> validate_inclusion(:status, @statuses)
  end

  def statuses, do: @statuses

  @doc "Is `status` a terminal state?"
  def terminal?(status) when is_binary(status),
    do: status in ~w(success failed error validation_failed unknown_action cancelled timed_out)

  def terminal?(_), do: false
end
