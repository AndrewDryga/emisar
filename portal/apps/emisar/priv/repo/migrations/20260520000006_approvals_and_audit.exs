defmodule Emisar.Repo.Migrations.ApprovalsAndAudit do
  use Ecto.Migration

  def change do
    # Approval requests: created when a run is decided to be allowed
    # *if approved*. Holds the run in :awaiting_approval until an
    # operator clicks approve or deny in the UI.
    create table(:approval_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :run_id, references(:action_runs, type: :binary_id, on_delete: :delete_all), null: false

      add :requested_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :requested_at, :utc_datetime_usec, null: false

      add :reason, :string
      add :context, :map, null: false, default: %{}

      add :status, :string, null: false, default: "pending"
      add :decided_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :decided_at, :utc_datetime_usec
      add :decision_reason, :string
      add :expires_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:approval_requests, [:account_id, :status])
    create index(:approval_requests, [:run_id])

    # Audit events are the system-of-record log. Cloud-side stream of
    # everything significant: user logins, agent registrations, policy
    # changes, approvals, action runs, etc. Designed for retention
    # tiers per pricing plan.
    create table(:audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :occurred_at, :utc_datetime_usec, null: false
      add :event_type, :string, null: false

      # Actor: who/what caused this.
      add :actor_kind, :string
      add :actor_id, :binary_id
      add :actor_label, :string

      # Subject: which entity this is about.
      add :subject_kind, :string
      add :subject_id, :binary_id
      add :subject_label, :string

      add :ip_address, :string
      add :user_agent, :string
      # Per-request id from Plug.RequestId — lets ops correlate an
      # audit row with the HTTP request that produced it in upstream
      # access logs.
      add :request_id, :string

      # Free-form structured payload — varies per event_type.
      add :payload, :map, null: false, default: %{}

      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:audit_events, [:account_id, :occurred_at])
    create index(:audit_events, [:account_id, :event_type])
    create index(:audit_events, [:subject_kind, :subject_id])
    create index(:audit_events, [:actor_kind, :actor_id])
  end
end
