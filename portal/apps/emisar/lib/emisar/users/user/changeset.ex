defmodule Emisar.Users.User.Changeset do
  use Emisar, :changeset
  alias Emisar.Users.User

  def registration(user, attrs) do
    user
    |> cast(attrs, [:email, :full_name])
    |> validate_email_field()
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

  def profile(user, attrs), do: cast(user, attrs, [:full_name])

  @doc """
  Create an SSO-provisioned user. Email is **optional** (a no-email IdP, or an
  unverified claim → nil) and is NOT required; when present it still hits the
  citext unique index, so a collision surfaces as a constraint error (mapped to
  `:email_taken`, never a silent merge). No password — the IdP is the
  credential; `confirmed_at` is set (the IdP is the email authority).
  """
  def sso_create(attrs) do
    %User{}
    |> cast(attrs, [:email, :full_name])
    |> validate_optional_email()
    |> put_change(:confirmed_at, DateTime.utc_now())
  end

  defp validate_optional_email(changeset) do
    if get_change(changeset, :email) do
      changeset
      |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/,
        message: "must have the @ sign and no spaces"
      )
      |> validate_length(:email, max: 160)
      |> unique_constraint(:email)
    else
      changeset
    end
  end

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
end
