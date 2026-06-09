defmodule Emisar.Accounts.User do
  @moduledoc """
  Users are identities that can sign in to the cloud UI. A user has
  one or more `Membership`s in accounts.
  """
  use Emisar, :schema

  schema "users" do
    field :email, :string
    field :full_name, :string

    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
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

    has_many :memberships, Emisar.Accounts.Membership
    has_many :accounts, through: [:memberships, :account]
    has_many :tokens, Emisar.Auth.UserToken

    timestamps()
  end

  @doc """
  Verifies the password. If there is no user or the user doesn't have
  a password, we call `Bcrypt.no_user_verify/0` to dodge timing attacks.
  """
  def valid_password?(%__MODULE__{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end
end
