defmodule Emisar.Approvals.Request do
  @moduledoc """
  An approval gate created when a run hit a require_approval rule.
  An operator with sufficient role clicks approve or deny in the UI;
  on approve the run transitions to `:sent` and cloud dispatches it.

  Statuses: `:pending` (awaiting a decision), `:approved`, `:denied`,
  `:expired` (timed out via the sweep), and `:cancelled` — set when the gated
  run itself was cancelled, so a stale approve can't resurrect + dispatch it.
  """
  use Emisar, :schema

  schema "approval_requests" do
    field :requested_at, :utc_datetime_usec
    field :reason, :string
    field :context, :map, default: %{}

    field :status, Ecto.Enum,
      values: [:pending, :approved, :denied, :expired, :cancelled],
      default: :pending

    field :decided_at, :utc_datetime_usec
    field :decision_reason, :string
    field :expires_at, :utc_datetime_usec

    # Approval-gate posture snapshotted from the policy at request creation,
    # mirroring the run-level policy_version snapshot — a later policy edit
    # can't move an in-flight request's bar.
    field :min_approvals, :integer, default: 1
    field :allow_self_approval, :boolean, default: true

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :run, Emisar.Runs.ActionRun
    belongs_to :requested_by, Emisar.Users.User, where: [deleted_at: nil]
    belongs_to :decided_by, Emisar.Users.User, where: [deleted_at: nil]

    has_many :decisions, Emisar.Approvals.Decision

    timestamps()
  end
end
