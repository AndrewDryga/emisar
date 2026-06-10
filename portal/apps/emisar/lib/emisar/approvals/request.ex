defmodule Emisar.Approvals.Request do
  @moduledoc """
  An approval gate created when a run hit a require_approval rule.
  An operator with sufficient role clicks approve or deny in the UI;
  on approve the run transitions to `:sent` and cloud dispatches it.
  """
  use Emisar, :schema

  schema "approval_requests" do
    field :requested_at, :utc_datetime_usec
    field :reason, :string
    field :context, :map, default: %{}
    field :status, Ecto.Enum, values: [:pending, :approved, :denied, :expired], default: :pending
    field :decided_at, :utc_datetime_usec
    field :decision_reason, :string
    field :expires_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :run, Emisar.Runs.ActionRun
    belongs_to :requested_by, Emisar.Users.User, where: [deleted_at: nil]
    belongs_to :decided_by, Emisar.Users.User, where: [deleted_at: nil]

    timestamps()
  end
end
