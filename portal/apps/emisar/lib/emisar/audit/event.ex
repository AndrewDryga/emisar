defmodule Emisar.Audit.Event do
  @moduledoc """
  The audit log. Append-only; the system of record for what happened
  in the cloud. Distinct from `Emisar.Runs.RunEvent` which is the
  per-run progress stream.
  """
  use Emisar, :schema

  schema "audit_events" do
    field :occurred_at, :utc_datetime_usec
    # The row's delete horizon, stamped at write time = occurred_at + the account's
    # then-current plan retention window. The retention sweep prunes rows past it, so
    # a later plan downgrade can't retroactively wipe history (only future rows shrink).
    field :retain_until, :utc_datetime_usec
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
    # How the actor authenticated this session (provenance, decision 6).
    field :auth_method, :string
    field :mfa, :boolean
    field :user_identity_id, Ecto.UUID
    field :payload, :map, default: %{}
    field :inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []}

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
  end
end
