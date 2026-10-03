defmodule Emisar.Fixtures.Auth do
  @moduledoc """
  Auth credential test fixtures. Use via `alias Emisar.Fixtures` then
  `Fixtures.Auth.create_session_token!/5`.
  """

  alias Emisar.Accounts.Membership
  alias Emisar.Auth.UserToken
  alias Emisar.Crypto
  alias Emisar.Repo
  alias Emisar.SSO

  @doc """
  The current TOTP code, never taken in the last two seconds of its 30-second
  step. A code is valid only within its own step, so near the end of one this
  waits for the next rather than hand a test a code that goes stale before the
  server checks it.
  """
  def totp_code(secret) when is_binary(secret) do
    left_ms = 30_000 - rem(System.os_time(:millisecond), 30_000)
    # A wall-clock wait, not synchronization: nothing can be received to mark
    # the start of the next step.
    # credo:disable-for-next-line Emisar.Checks.TestNoProcessSleep
    if left_ms < 2_000, do: Process.sleep(left_ms + 10)
    NimbleTOTP.verification_code(secret)
  end

  @doc "Extracts the six-character code from a transactional email's dedicated code line."
  def code_from_email(%{text_body: text_body}) when is_binary(text_body) do
    [_, code] = Regex.run(~r/^    ([0-9A-Z]{6})$/m, text_body)
    code
  end

  @doc """
  Persists one token in an exact `context`, aged to `inserted_at` — the arrange
  for the retention sweep, which judges each row against its own context's
  validity window. A `nil` Member makes the one owner-less row, a `sign_up`
  code.
  """
  def create_aged_token!(membership, context, %DateTime{} = inserted_at)
      when is_binary(context) do
    {_raw, digest} = Crypto.email_token()

    token =
      membership
      |> aged_token(digest, context)
      |> Repo.insert!()

    {1, _} = UserToken.Query.by_id(token.id) |> Repo.update_all(set: [inserted_at: inserted_at])

    Repo.reload!(token)
  end

  defp aged_token(nil, digest, "sign_up") do
    UserToken.Changeset.sign_up(digest, Emisar.Fixtures.Random.unique_email(), 5, %{
      account_name: "Aged Workspace",
      full_name: "Aged Person"
    })
  end

  defp aged_token(%Membership{} = membership, digest, "session") do
    UserToken.Changeset.session(membership, digest, Crypto.hash(Crypto.random_secret()), %{}, nil)
  end

  defp aged_token(%Membership{} = membership, digest, context) do
    Ecto.Changeset.change(%UserToken{},
      token: digest,
      context: context,
      sent_to: membership.email,
      account_id: membership.account_id,
      membership_id: membership.id
    )
  end

  @doc "Backdates one session token's insertion time and returns `:ok`."
  def backdate_session_token!(token, inserted_at)
      when is_binary(token) and is_struct(inserted_at, DateTime) do
    {1, _} =
      UserToken.Query.by_token_digest(Crypto.hash(token))
      |> Repo.update_all(set: [inserted_at: inserted_at])

    :ok
  end

  @doc "Backdates a token's insertion time by id and returns `:ok`."
  def backdate_token_inserted_at!(token_id, %DateTime{} = inserted_at) when is_binary(token_id) do
    {1, _} = UserToken.Query.by_id(token_id) |> Repo.update_all(set: [inserted_at: inserted_at])
    :ok
  end

  @doc "Removes a session row to arrange a stale session list."
  def delete_session_token!(token) when is_binary(token) do
    {1, _} =
      UserToken.Query.by_token_digest(Crypto.hash(token))
      |> Repo.delete_all()

    :ok
  end

  @doc "Expires a session's local-factor proof without ending the session or its SSO route."
  def expire_local_mfa_proof!(raw) when is_binary(raw) do
    expired_at = DateTime.add(DateTime.utc_now(), -1, :second)

    {1, _} =
      UserToken.Query.by_token_digest(Crypto.hash(raw))
      |> Repo.update_all(set: [local_mfa_expires_at: expired_at])

    :ok
  end

  @doc """
  Persists a session row for one Member with arbitrary provenance and returns
  the raw token. `mfa_verified_at` is when this session proved a second factor,
  or nil for never; a local proof binds the session to the Member's current
  enrollment (read from the row, so a struct loaded before enrollment still
  binds). `:sso` needs `user_identity_id:` and freezes that identity's subject
  and its provider's issuer, as a real SSO sign-in does. `browser_id:` names
  the minting browser (a random one by default).

  Production never mints a session this way — every sign-in flow owns its own
  provenance (`Auth.complete_magic_link_sign_in/4`,
  `Auth.complete_magic_link_mfa_sign_in/4`, `Auth.complete_sso_sign_in/5`)
  precisely so no caller can hand-pick `auth_method`/`mfa_verified_at`. This is
  the test arrange for everything that only needs *a* live session to exist.
  """
  def create_session_token!(
        %Membership{} = membership,
        auth_method \\ :magic_link,
        mfa_verified_at \\ nil,
        metadata \\ %{},
        opts \\ []
      ) do
    {token, digest} = Crypto.session_token()
    browser_digest = Crypto.hash(Keyword.get_lazy(opts, :browser_id, &Crypto.random_secret/0))
    membership = Repo.reload(membership) || membership

    membership
    |> session_changeset(auth_method, digest, browser_digest, metadata, mfa_verified_at, opts)
    |> Repo.insert!()

    token
  end

  defp session_changeset(
         membership,
         :magic_link,
         digest,
         browser_digest,
         metadata,
         mfa_at,
         _opts
       ),
       do: UserToken.Changeset.session(membership, digest, browser_digest, metadata, mfa_at)

  defp session_changeset(membership, :sso, digest, browser_digest, metadata, mfa_at, opts) do
    identity_id =
      Keyword.get(opts, :user_identity_id) ||
        raise ArgumentError, "an :sso session needs the user_identity_id: it signed in through"

    identity = Repo.get!(SSO.UserIdentity, identity_id)
    provider = Repo.get!(SSO.IdentityProvider, identity.provider_id)

    membership
    |> UserToken.Changeset.sso_session(digest, browser_digest, metadata, identity, provider)
    |> Ecto.Changeset.put_change(:mfa_verified_at, mfa_at)
  end
end
