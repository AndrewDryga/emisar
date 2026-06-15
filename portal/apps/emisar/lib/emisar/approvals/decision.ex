defmodule Emisar.Approvals.Decision do
  @moduledoc """
  One operator's recorded vote on an `Emisar.Approvals.Request`. A request
  finalizes (dispatches the run, or cancels it) once enough DISTINCT
  approvers vote — distinctness enforced by the `(request_id, decider_id)`
  unique index, never an app-side count.
  """
  use Emisar, :schema

  schema "approval_decisions" do
    field :decision, Ecto.Enum, values: [:approve, :deny]
    field :reason, :string
    field :decided_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :request, Emisar.Approvals.Request
    belongs_to :decider, Emisar.Users.User, where: [deleted_at: nil]

    timestamps()
  end
end
