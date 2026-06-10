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
    field :status, :string, default: "pending"
    field :decided_at, :utc_datetime_usec
    field :decision_reason, :string
    field :expires_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account
    belongs_to :run, Emisar.Runs.ActionRun
    belongs_to :requested_by, Emisar.Accounts.User
    belongs_to :decided_by, Emisar.Accounts.User

    timestamps()
  end

  def statuses, do: Emisar.Approvals.Request.Changeset.statuses()
end
