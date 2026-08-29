defmodule Emisar.Fixtures.Users do
  @moduledoc """
  User test fixtures. Use via `alias Emisar.Fixtures` then
  `Fixtures.Users.create_user/1`.
  """

  alias Emisar.Auth.Subject
  alias Emisar.Fixtures
  alias Emisar.Users.User

  @mfa_state_fields [:mfa_secret, :mfa_enabled_at, :mfa_recovery_codes]

  @doc "Persists a user. Defaults to confirmed."
  def create_user(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    confirmed? = Map.get(attrs, :confirmed?, true)

    cast_attrs =
      %{email: Fixtures.Random.unique_email(), full_name: "Test User"}
      |> Map.merge(attrs)
      |> Map.drop([:confirmed?])

    {:ok, user} =
      %User{}
      |> User.Changeset.registration(cast_attrs)
      |> Emisar.Repo.insert()

    if confirmed?, do: confirm_user(user), else: user
  end

  @doc "Marks a user's email confirmed, bypassing the token flow. Test/seed convenience."
  def confirm_user(%User{} = user) do
    {:ok, user} = user |> User.Changeset.confirm() |> Emisar.Repo.update()
    user
  end

  @doc "Updates a user's email as test setup, bypassing the self-service step-up flow."
  def update_email(%User{} = user, email) when is_binary(email) do
    {:ok, user} = user |> User.Changeset.email(%{email: email}) |> Emisar.Repo.update()
    user
  end

  @doc "Sets a user's global sign-in timestamp directly."
  def set_last_sign_in_at(%User{} = user, %DateTime{} = last_sign_in_at) do
    {:ok, updated} =
      user
      |> Ecto.Changeset.change(last_sign_in_at: last_sign_in_at)
      |> Emisar.Repo.update()

    updated
  end

  @doc """
  Flags a user as Emisar staff. `is_admin` has no production write path — it is
  set out of band, so no changeset casts it — and it is a GLOBAL flag, wholly
  separate from the account roles a membership carries.
  """
  def mark_user_as_staff(%User{} = user) do
    {:ok, staff_user} = user |> Ecto.Changeset.change(is_admin: true) |> Emisar.Repo.update()
    staff_user
  end

  @doc """
  Revokes a user's Emisar staff flag, returning the un-flagged row. The
  counterpart write to `mark_user_as_staff/1` — it exists so a test can hold a
  struct that still SAYS `is_admin: true` while the row no longer does.
  """
  def revoke_user_staff(%User{} = user) do
    {:ok, revoked_user} = user |> Ecto.Changeset.change(is_admin: false) |> Emisar.Repo.update()
    revoked_user
  end

  @doc "Soft-deletes a user, returning the tombstoned row."
  def mark_user_as_deleted(%User{} = user) do
    {:ok, deleted} = user |> User.Changeset.delete() |> Emisar.Repo.update()
    deleted
  end

  @doc "Rigs stored MFA state directly for tests that exercise later lifecycle transitions."
  def set_mfa_state(%User{} = user, attrs) do
    attrs = Map.new(attrs)

    case Map.keys(attrs) -- @mfa_state_fields do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown MFA state fields: #{inspect(Enum.sort(unknown))}"
    end

    user
    |> Ecto.Changeset.change(Map.take(attrs, @mfa_state_fields))
    |> Emisar.Repo.update!()
  end

  @doc """
  Enrolls TOTP MFA through the real current-inbox proof and returns its tagged result
  (`{:ok, user, recovery_codes}` / `{:error, reason}`). Generating a code with
  `NimbleTOTP.verification_code/1` and validating it inside `enable_mfa` reads the
  clock twice; if a 30s window boundary falls between the two reads the code is
  already stale and `enable_mfa` returns `{:error, :invalid_otp}` — a rare flake.
  Retry once across the boundary: a second straddle can't happen microseconds later.
  A test asserting `enable_mfa`'s success contract calls this directly; `enable_mfa!`
  wraps it for setup sites that just need an MFA-enabled user.
  """
  def enroll_mfa(secret, %Subject{} = subject, opts \\ []) when is_binary(secret) do
    {session_token, disposable_session?} =
      case Keyword.fetch(opts, :session_token) do
        {:ok, token} -> {token, false}
        :error -> {Fixtures.Auth.create_session_token!(subject.actor, :magic_link, nil), true}
      end

    try do
      proof = mfa_enrollment_proof(subject)
      session_digest = Emisar.Crypto.hash(session_token)

      case Emisar.Auth.enable_mfa(
             secret,
             NimbleTOTP.verification_code(secret),
             proof,
             session_digest,
             subject
           ) do
        {:error, :invalid_otp} ->
          Emisar.Auth.enable_mfa(
            secret,
            NimbleTOTP.verification_code(secret),
            proof,
            session_digest,
            subject
          )

        enrolled ->
          enrolled
      end
    after
      if disposable_session?, do: Emisar.Auth.delete_session_token(session_token)
    end
  end

  @doc "Issues and verifies the real current-inbox proof used by MFA enrollment tests."
  def mfa_enrollment_proof(%Subject{} = subject) do
    {:ok, :sent} = Emisar.Auth.issue_mfa_enrollment_code(subject)

    email =
      receive do
        {:email, email} -> email
      after
        1_000 -> raise "MFA enrollment code email was not delivered"
      end

    code = Fixtures.Auth.code_from_email(email)
    {:ok, proof} = Emisar.Auth.verify_mfa_enrollment_code(code, subject)
    proof
  end

  @doc "Enrolls MFA as test setup, unwrapping `enroll_mfa/2` to `{user, recovery_codes}`."
  def enable_mfa!(secret, %Subject{} = subject, opts \\ []) when is_binary(secret) do
    {:ok, user, codes} = enroll_mfa(secret, subject, opts)
    {user, codes}
  end
end
