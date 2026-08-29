defmodule Emisar.Fixtures.Auth do
  @moduledoc """
  Auth credential test fixtures. Use via `alias Emisar.Fixtures` then
  `Fixtures.Auth.create_session_token!/5`.
  """

  alias Emisar.Auth.UserToken
  alias Emisar.Crypto
  alias Emisar.Repo
  alias Emisar.Users.User

  @doc "Extracts the six-digit code from a transactional email's dedicated code line."
  def code_from_email(%{text_body: text_body}) when is_binary(text_body) do
    [_, code] = Regex.run(~r/^    (\d{6})$/m, text_body)
    code
  end

  @doc "Persists a raw confirmation factor for a consumer/controller test."
  def create_confirmation_token!(%User{} = user) do
    {raw, digest} = Crypto.email_token()
    Repo.insert!(UserToken.Changeset.hashed(user, digest, "confirm", user.email))
    raw
  end

  @doc """
  Persists one token in an exact `context`, aged to `inserted_at` — the arrange
  for the retention sweep, which judges each row against its own context's
  validity window.
  """
  def create_aged_token!(%User{} = user, context, %DateTime{} = inserted_at)
      when is_binary(context) do
    {_raw, digest} = Crypto.email_token()
    token = Repo.insert!(UserToken.Changeset.hashed(user, digest, context, user.email))

    {1, _} = UserToken.Query.by_id(token.id) |> Repo.update_all(set: [inserted_at: inserted_at])

    Repo.reload!(token)
  end

  @doc "Backdates one session token's insertion time and returns `:ok`."
  def backdate_session_token!(token, inserted_at)
      when is_binary(token) and is_struct(inserted_at, DateTime) do
    {1, _} =
      UserToken.Query.by_token_digest(Crypto.hash(token))
      |> Repo.update_all(set: [inserted_at: inserted_at])

    :ok
  end

  @doc """
  Persists a session row with arbitrary provenance and returns the raw token.
  `mfa_verified_at` is when this session proved a second factor, or nil for
  never; pass an explicit `DateTime` when a test turns on how that stamp sits
  against the user's `mfa_enabled_at`.

  Production never mints a session this way — every sign-in flow owns its own
  provenance (`Auth.complete_magic_link_sign_in/4`,
  `Auth.complete_magic_link_mfa_sign_in/4`, `Auth.complete_sso_account_sign_in/4`)
  precisely so no caller can hand-pick `auth_method`/`mfa_verified_at`. This is
  the test arrange for everything that only needs *a* live session to exist.
  """
  def create_session_token!(
        %User{} = user,
        auth_method,
        mfa_verified_at,
        metadata \\ %{},
        opts \\ []
      ) do
    {token, digest} = Crypto.session_token()

    Repo.insert!(
      UserToken.Changeset.session(user, digest, metadata, auth_method, mfa_verified_at, opts)
    )

    token
  end

  @doc """
  Rewrites every session's `auth_method` to a value the enum no longer has —
  a legacy `password` session from before the passwordless rework.

  The DB now CHECKs this column, and a real deploy narrows the enum in the same
  release that adds the constraint, so the window this defends is the rows
  written before that migration ran. Dropping the constraint reproduces that
  window; the sandbox transaction rolls the drop back with everything else.
  """
  def write_removed_auth_method!(value \\ "password") do
    Ecto.Adapters.SQL.query!(
      Repo,
      "ALTER TABLE auth_user_tokens DROP CONSTRAINT auth_user_tokens_auth_method_check",
      []
    )

    Ecto.Adapters.SQL.query!(Repo, "UPDATE auth_user_tokens SET auth_method = $1", [value])
  end
end
