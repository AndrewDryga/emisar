defmodule Emisar.Fixtures.Auth do
  @moduledoc """
  Auth credential test fixtures. Use via `alias Emisar.Fixtures` then
  `Fixtures.Auth.create_session_token!/5`.
  """

  alias Emisar.Auth.UserToken
  alias Emisar.Crypto
  alias Emisar.Repo
  alias Emisar.Users.User

  @doc """
  Persists a session row with arbitrary provenance and returns the raw token.
  `mfa_verified_at` is when this session proved a second factor, or nil for
  never; pass an explicit `DateTime` when a test turns on how that stamp sits
  against the user's `mfa_enabled_at`.

  Production never mints a session this way — every sign-in flow owns its own
  provenance (`Auth.complete_magic_link_sign_in/3`,
  `Auth.complete_magic_link_mfa_sign_in/3`, `Auth.complete_sso_account_sign_in/5`)
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
