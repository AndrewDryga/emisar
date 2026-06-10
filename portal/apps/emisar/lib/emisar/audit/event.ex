defmodule Emisar.Audit.Event do
  @moduledoc """
  The audit log. Append-only; the system of record for what happened
  in the cloud. Distinct from `Emisar.Runs.RunEvent` which is the
  per-run progress stream.
  """
  use Emisar, :schema

  schema "audit_events" do
    field :occurred_at, :utc_datetime_usec
    field :event_type, :string

    field :actor_kind, :string
    field :actor_id, Ecto.UUID
    field :actor_label, :string

    field :subject_kind, :string
    field :subject_id, Ecto.UUID
    field :subject_label, :string

    field :ip_address, :string
    field :user_agent, :string
    field :request_id, :string
    field :mcp_session_id, :string
    field :payload, :map, default: %{}
    field :inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []}

    belongs_to :account, Emisar.Accounts.Account
  end
end
