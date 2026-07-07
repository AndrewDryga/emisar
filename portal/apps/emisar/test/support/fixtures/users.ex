defmodule Emisar.Fixtures.Users do
  @moduledoc """
  User test fixtures. Use via `alias Emisar.Fixtures` then
  `Fixtures.Users.create_user/1`.
  """

  alias Emisar.Auth.Subject
  alias Emisar.Fixtures
  alias Emisar.Users.User

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

  @doc """
  Enrolls TOTP MFA for `subject` via `Auth.enable_mfa` and returns its tagged result
  (`{:ok, user, recovery_codes}` / `{:error, reason}`). Generating a code with
  `NimbleTOTP.verification_code/1` and validating it inside `enable_mfa` reads the
  clock twice; if a 30s window boundary falls between the two reads the code is
  already stale and `enable_mfa` returns `{:error, :invalid_otp}` — a rare flake.
  Retry once across the boundary: a second straddle can't happen microseconds later.
  A test asserting `enable_mfa`'s success contract calls this directly; `enable_mfa!`
  wraps it for setup sites that just need an MFA-enabled user.
  """
  def enroll_mfa(secret, %Subject{} = subject) when is_binary(secret) do
    case Emisar.Auth.enable_mfa(secret, NimbleTOTP.verification_code(secret), subject) do
      {:error, :invalid_otp} ->
        Emisar.Auth.enable_mfa(secret, NimbleTOTP.verification_code(secret), subject)

      enrolled ->
        enrolled
    end
  end

  @doc "Enrolls MFA as test setup, unwrapping `enroll_mfa/2` to `{user, recovery_codes}`."
  def enable_mfa!(secret, %Subject{} = subject) when is_binary(secret) do
    {:ok, user, codes} = enroll_mfa(secret, subject)
    {user, codes}
  end
end
