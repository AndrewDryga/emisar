defmodule Emisar.Repo.Migrations.RunsAndEvents do
  use Ecto.Migration

  def change do
    # An action run is one outstanding invocation against a specific
    # runner. It begins life as :pending (cloud has decided to invoke
    # but hasn't sent the run_action over the wire yet), then moves
    # through :sent -> :running -> terminal status (:success, :failed,
    # :validation_failed, :unknown_action, :error, :cancelled).
    create table(:action_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all), null: false
      add :runner_id, references(:runners, type: :binary_id, on_delete: :delete_all), null: false

      # request_id is the wire protocol's correlation key. Globally
      # unique within an account; passed to the runner as
      # run_action.request_id and echoed back on action_progress +
      # action_result.
      add :request_id, :string, null: false

      # What's being run.
      add :action_id, :string, null: false
      add :runbook_id, references(:runbooks, type: :binary_id, on_delete: :nilify_all)
      add :runbook_step_id, :string

      # Who/what asked. Either a user (operator manually triggered),
      # a runbook step (orchestrated), an LLM via MCP (api_key_id),
      # or a scheduled job.
      add :requested_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :api_key_id, :binary_id
      add :source, :string, null: false, default: "operator"
      add :reason, :string

      # Inputs and clamped opts.
      add :args, :map, null: false, default: %{}
      add :args_sha256, :string
      add :opts, :map, null: false, default: %{}

      # Policy decision snapshot.
      add :policy_id, references(:policies, type: :binary_id, on_delete: :nilify_all)
      add :policy_decision, :string
      add :policy_reason, :string
      add :matched_rules, {:array, :string}, null: false, default: []

      # Approval state. If the policy required approval, the run sits
      # in :awaiting_approval until granted (see approvals table).
      add :requires_approval, :boolean, null: false, default: false
      add :approval_request_id, :binary_id

      # Lifecycle timestamps.
      add :status, :string, null: false, default: "pending"
      add :queued_at, :utc_datetime_usec
      add :sent_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :cancelled_at, :utc_datetime_usec

      # Result (filled in on completion).
      add :exit_code, :integer
      add :duration_ms, :integer
      add :timed_out, :boolean, null: false, default: false
      add :stdout_sha256, :string
      add :stderr_sha256, :string
      add :stdout_bytes, :bigint
      add :stderr_bytes, :bigint
      add :event_id, :string
      add :reason_text, :string
      add :error_message, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:action_runs, [:account_id, :request_id])
    create index(:action_runs, [:account_id, :status])
    create index(:action_runs, [:runner_id, :status])
    create index(:action_runs, [:account_id, :action_id])
    create index(:action_runs, [:runbook_id])
    create index(:action_runs, [:requested_by_id])

    # Streamed progress chunks + runner-emitted state transitions.
    # Many rows per run; we cap retention via Oban job.
    create table(:action_run_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, references(:action_runs, type: :binary_id, on_delete: :delete_all), null: false
      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all), null: false

      add :seq, :integer, null: false
      add :kind, :string, null: false
      add :stream, :string
      add :payload, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:action_run_events, [:run_id, :seq])
    create index(:action_run_events, [:account_id, :inserted_at])
  end
end
