defmodule Emisar.Admin.Staff do
  @moduledoc """
  An Emisar staff login: the only principal the staff console and LiveDashboard
  accept.

  It is not a workspace Member, and nothing a workspace, an identity provider, a
  directory or configuration controls can create or change one. Rows are
  created, reset and removed only by the `Emisar.Release` staff commands run on
  the production node, which show the authenticator secret once. Every sign-in needs an emailed code and the current authenticator
  code; there are no recovery codes.
  """
  use Emisar, :schema

  schema "admin_staff" do
    field :email, :string
    field :mfa_secret, :binary, redact: true
    # The newest TOTP bucket this login signed in with; a code from that bucket
    # or an older one is a replay.
    field :mfa_last_used_at, :utc_datetime_usec
    # Consecutive wrong authenticator codes that followed a correct emailed
    # code. At the limit the login is locked until a reset on the box.
    field :failed_mfa_attempts, :integer, default: 0

    timestamps()
  end
end
