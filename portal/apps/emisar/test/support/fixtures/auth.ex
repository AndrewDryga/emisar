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
end
