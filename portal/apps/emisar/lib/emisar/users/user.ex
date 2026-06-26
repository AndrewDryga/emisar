defmodule Emisar.Users.User do
  @moduledoc """
  Users are identities that can sign in to the cloud UI. Identity is
  deliberately cross-account: a user holds one or more
  `Emisar.Accounts.Membership`s, each joining them to a tenant.
  """
  use Emisar, :schema

  schema "users" do
    field :email, :string
    field :full_name, :string
    field :confirmed_at, :utc_datetime_usec

    field :mfa_secret, :binary, redact: true
    field :mfa_enabled_at, :utc_datetime_usec
    # Most-recent TOTP step counter the user authenticated with;
    # `verify_mfa/2` refuses replays inside the same 30s window.
    field :mfa_last_used_at, :utc_datetime_usec
    # Backup codes stored as `:crypto.hash(:sha256, raw)` so a DB leak
    # doesn't surface the codes themselves. Consumed on use.
    field :mfa_recovery_codes, {:array, :binary}, default: [], redact: true

    field :last_sign_in_at, :utc_datetime_usec
    field :is_admin, :boolean, default: false
    field :deleted_at, :utc_datetime_usec

    has_many :memberships, Emisar.Accounts.Membership, where: [deleted_at: nil]
    # `through:` can't take a `:where` — it inherits the filters of the
    # associations it traverses (memberships above + Membership.account).
    has_many :accounts, through: [:memberships, :account]
    has_many :tokens, Emisar.Auth.UserToken

    timestamps()
  end
end
