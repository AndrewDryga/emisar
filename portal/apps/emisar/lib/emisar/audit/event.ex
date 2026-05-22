defmodule Emisar.Audit.Event do
  @moduledoc """
  The audit log. Append-only; the system of record for what happened
  in the cloud. Distinct from `Emisar.Runs.RunEvent` which is the
  per-run progress stream.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

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
    field :payload, :map, default: %{}
    field :inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []}

    belongs_to :account, Emisar.Accounts.Account
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :account_id, :occurred_at, :event_type,
      :actor_kind, :actor_id, :actor_label,
      :subject_kind, :subject_id, :subject_label,
      :ip_address, :user_agent, :payload
    ])
    |> validate_required([:account_id, :occurred_at, :event_type])
  end
end
