defmodule Emisar.Users.User.Changeset do
  use Emisar, :changeset
  alias Emisar.Users.User

  # The column is a varchar(255), and nothing bounded the field — so a longer
  # name reached Postgres and came back as a 500 rather than a rejected change.
  @full_name_max_length 255

  def registration(user, attrs) do
    user
    |> cast(attrs, [:email, :full_name])
    |> validate_full_name()
    |> validate_email_field()
  end

  @doc """
  Internal — advances the address generation and clears the previous address's
  confirmation. Auth proves both factors before composing this change with
  confirmation of the NEW address in the same transaction; this changeset alone
  never transfers the old address's confirmation to a different mailbox.
  """
  def email(user, attrs) do
    user
    |> cast(attrs, [:email])
    |> validate_email_field()
    |> case do
      %{changes: %{email: _}} = changeset ->
        change(changeset,
          confirmed_at: nil,
          email_changed_at: next_email_changed_at(user)
        )

      %{} = changeset ->
        add_error(changeset, :email, "did not change")
    end
  end

  def profile(user, attrs), do: user |> cast(attrs, [:full_name]) |> validate_full_name()

  defp validate_full_name(changeset),
    do: validate_length(changeset, :full_name, max: @full_name_max_length)

  defp next_email_changed_at(%User{email_changed_at: %DateTime{} = previous}) do
    now = DateTime.utc_now()
    if DateTime.after?(now, previous), do: now, else: DateTime.add(previous, 1, :microsecond)
  end

  defp next_email_changed_at(%User{}), do: DateTime.utc_now()

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

  @doc "Replace the stored recovery digests — one consumed, or a whole new set."
  def mfa_recovery_codes(%User{} = user, codes) when is_list(codes),
    do: change(user, mfa_recovery_codes: codes)

  @doc "Atomically replace recovery digests and consume the proving TOTP bucket."
  def regenerated_mfa_recovery_codes(%User{} = user, codes, %DateTime{} = at)
      when is_list(codes),
      do: change(user, mfa_recovery_codes: codes, mfa_last_used_at: at)

  def delete(%User{} = user), do: change(user, deleted_at: DateTime.utc_now())

  # The citext unique index is the uniqueness source of truth (IL-8:
  # changesets are pure — no Repo pre-check); `unique_constraint` maps
  # the violation back onto the :email field.
  defp validate_email_field(changeset) do
    changeset
    |> validate_required([:email])
    |> Emisar.EmailAddress.validate(:email)
    |> unique_constraint(:email)
  end
end
