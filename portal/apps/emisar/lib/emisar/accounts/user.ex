defmodule Emisar.Accounts.User do
  @moduledoc """
  Users are identities that can sign in to the cloud UI. A user has
  one or more `Membership`s in accounts.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users" do
    field :email, :string
    field :full_name, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :confirmed_at, :utc_datetime_usec
    field :mfa_secret, :binary, redact: true
    field :mfa_enabled_at, :utc_datetime_usec
    field :last_sign_in_at, :utc_datetime_usec
    field :is_admin, :boolean, default: false

    has_many :memberships, Emisar.Accounts.Membership
    has_many :accounts, through: [:memberships, :account]
    has_many :tokens, Emisar.Auth.UserToken

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for fresh registrations: email + password (optional).
  Magic-link signup omits the password.
  """
  def registration_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email, :full_name, :password])
    |> validate_email()
    |> validate_optional_password(opts)
  end

  def email_changeset(user, attrs) do
    user
    |> cast(attrs, [:email])
    |> validate_email()
    |> case do
      %{changes: %{email: _}} = changeset -> changeset
      %{} = changeset -> add_error(changeset, :email, "did not change")
    end
  end

  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password(opts)
  end

  def profile_changeset(user, attrs) do
    cast(user, attrs, [:full_name])
  end

  def confirm_changeset(user) do
    change(user, confirmed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond))
  end

  def sign_in_changeset(user) do
    change(user, last_sign_in_at: DateTime.utc_now() |> DateTime.truncate(:microsecond))
  end

  def mfa_changeset(user, secret, enabled_at) do
    change(user, mfa_secret: secret, mfa_enabled_at: enabled_at)
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

  defp validate_email(changeset) do
    changeset
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> validate_length(:email, max: 160)
    |> unsafe_validate_unique(:email, Emisar.Repo)
    |> unique_constraint(:email)
  end

  defp validate_optional_password(changeset, opts) do
    if get_change(changeset, :password) do
      validate_password(changeset, opts)
    else
      changeset
    end
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 12, max: 128)
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end
end
