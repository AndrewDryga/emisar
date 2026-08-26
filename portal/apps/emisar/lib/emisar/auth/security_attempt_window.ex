defmodule Emisar.Auth.SecurityAttemptWindow do
  @moduledoc """
  One durable, cluster-wide fixed-window budget for a user's credential checks.

  Coarse route and network abuse controls remain in node-local ETS. This row is
  reserved for authenticated or partially authenticated per-user proofs whose
  attempt budget must survive reconnects, restarts, and concurrent Portal nodes.
  """
  use Emisar, :schema

  @scopes [
    :mfa_challenge,
    :inbox_step_up,
    :email_change_issue,
    :mfa_enrollment_issue,
    :oidc_identity_step_up_issue
  ]

  schema "auth_security_attempt_windows" do
    field :scope, Ecto.Enum, values: @scopes
    field :attempt_count, :integer, default: 0
    field :window_started_at, :utc_datetime_usec
    field :window_expires_at, :utc_datetime_usec

    belongs_to :user, Emisar.Users.User, where: [deleted_at: nil]

    timestamps()
  end

  def scopes, do: @scopes
end
