defmodule Emisar.Approvals.Request do
  @moduledoc """
  An approval gate created when a run hit a require_approval rule.
  An operator with sufficient role clicks approve or deny in the UI;
  on approve the run transitions to `:sent` and cloud dispatches it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending approved denied expired)

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

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(req, attrs) do
    req
    |> cast(attrs, [:account_id, :run_id, :requested_by_id, :requested_at, :reason, :context, :expires_at])
    |> validate_required([:account_id, :run_id, :requested_at])
  end

  def decide_changeset(req, status, decided_by_id, reason \\ nil) do
    req
    |> change(
      status: to_string(status),
      decided_by_id: decided_by_id,
      decided_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      decision_reason: reason
    )
    |> validate_inclusion(:status, @statuses)
  end

  def statuses, do: @statuses
end
