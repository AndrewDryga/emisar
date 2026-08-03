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

  Production never mints a session this way — every sign-in flow owns its own
  provenance (`Auth.complete_magic_link_sign_in/3`,
  `Auth.complete_magic_link_mfa_sign_in/3`, `Auth.complete_sso_account_sign_in/5`)
  precisely so no caller can hand-pick `auth_method`/`mfa`. This is the test
  arrange for everything that only needs *a* live session to exist.
  """
  def create_session_token!(%User{} = user, auth_method, mfa, metadata \\ %{}, opts \\ []) do
    {token, digest} = Crypto.session_token()
    Repo.insert!(UserToken.Changeset.session(user, digest, metadata, auth_method, mfa, opts))
    token
  end
end
