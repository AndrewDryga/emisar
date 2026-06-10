defmodule Emisar.Accounts.User.Changeset do
  use Emisar, :changeset
  alias Emisar.Accounts.User

  def registration(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email, :full_name, :password])
    |> validate_email_field()
    |> validate_optional_password(opts)
  end

  def email(user, attrs) do
    user
    |> cast(attrs, [:email])
    |> validate_email_field()
    |> case do
      %{changes: %{email: _}} = changeset -> changeset
      %{} = changeset -> add_error(changeset, :email, "did not change")
    end
  end

  def password(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password_field(opts)
  end

  def profile(user, attrs), do: cast(user, attrs, [:full_name])

  def confirm(%User{} = user),
    do: change(user, confirmed_at: DateTime.utc_now())

  def sign_in(%User{} = user),
    do: change(user, last_sign_in_at: DateTime.utc_now())

  @doc """
  Toggle MFA. `secret`/`enabled_at` both non-nil → enable; both nil →
  disable. `recovery_codes` is the digest list (hashed at the caller),
  refreshed every time we re-enable so old codes don't survive a
  toggle. `mfa_last_used_at` is wiped on enable so the replay guard
  starts clean.
  """
  def mfa(%User{} = user, secret, enabled_at, recovery_codes \\ []) do
    change(user,
      mfa_secret: secret,
      mfa_enabled_at: enabled_at,
      mfa_recovery_codes: recovery_codes,
      mfa_last_used_at: nil
    )
  end

  @doc "Stamp the timestamp of the most recent successful TOTP — used by Auth's replay guard."
  def mfa_consumed(%User{} = user, at),
    do: change(user, mfa_last_used_at: at)

  @doc "Persist the remaining recovery codes after one is consumed."
  def mfa_recovery_codes(%User{} = user, codes) when is_list(codes),
    do: change(user, mfa_recovery_codes: codes)

  def delete(%User{} = user), do: change(user, deleted_at: DateTime.utc_now())

  # The citext unique index is the uniqueness source of truth (IL-8:
  # changesets are pure — no Repo pre-check); `unique_constraint` maps
  # the violation back onto the :email field.
  defp validate_email_field(changeset) do
    changeset
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> validate_length(:email, max: 160)
    |> unique_constraint(:email)
  end

  defp validate_optional_password(changeset, opts) do
    if get_change(changeset, :password),
      do: validate_password_field(changeset, opts),
      else: changeset
  end

  defp validate_password_field(changeset, opts) do
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
