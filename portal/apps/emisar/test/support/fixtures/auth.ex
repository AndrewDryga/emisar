defmodule Emisar.Fixtures.Auth do
  @moduledoc """
  Auth credential test fixtures. Use via `alias Emisar.Fixtures` then
  `Fixtures.Auth.create_session_token!/5`.
  """

  alias Emisar.{Accounts, SSO}
  alias Emisar.Auth.{SessionGrants, UserToken}
  alias Emisar.Crypto
  alias Emisar.Repo
  alias Emisar.Users.User

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

  @doc "Expires independent personal and local-factor proof without ending the session or its SSO routes."
  def expire_session_independent_proofs!(raw) do
    expired_at = DateTime.add(DateTime.utc_now(), -1, :second)

    {1, _} =
      UserToken.Query.by_token_digest(Crypto.hash(raw))
      |> Repo.update_all(set: [personal_expires_at: expired_at, local_mfa_expires_at: expired_at])

    :ok
  end

  @doc """
  Persists a session row with arbitrary provenance and returns the raw token.
  `mfa_verified_at` is when this session proved a second factor, or nil for
  never; pass an explicit `DateTime` when a test turns on how that stamp sits
  against the user's `mfa_enabled_at`.

  Production never mints a session this way — every sign-in flow owns its own
  provenance (`Auth.complete_magic_link_sign_in/5`,
  `Auth.complete_magic_link_mfa_sign_in/5`, `Auth.complete_sso_account_sign_in/4`)
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

    session =
      Repo.insert!(
        UserToken.Changeset.session(user, digest, metadata, auth_method, mfa_verified_at, opts)
      )

    insert_fixture_grants(session, user, auth_method, opts)

    token
  end

  @doc """
  Persists a member-only SSO session for a Member without a personal login and
  returns the raw token. The row is the member-only session changeset; its one
  frozen grant comes from the real sign-in authority for `identity`.
  """
  def create_member_session_token!(
        %Accounts.Membership{user_id: nil} = membership,
        %SSO.UserIdentity{} = identity,
        metadata \\ %{}
      ) do
    {token, digest} = Crypto.session_token()

    {:ok, _changes} =
      Ecto.Multi.new()
      |> SSO.put_sign_in_authority(membership, identity.account_id,
        user_identity_id: identity.id,
        provider_identifier: identity.provider_identifier
      )
      |> Ecto.Multi.insert(:session, fn %{sso_provider: provider} ->
        mfa_verified_at = if provider.satisfies_mfa, do: DateTime.utc_now()
        UserToken.Changeset.member_session(digest, metadata, mfa_verified_at, identity.id)
      end)
      |> Ecto.Multi.run(:fixture_grants, fn repo, changes ->
        SessionGrants.insert_sso(repo, changes.session, changes.sso_destinations)
      end)
      |> Repo.commit_multi()

    token
  end

  # Consumers need the same frozen authority shape as a real sign-in. These
  # fixtures never make grantless tokens authoritative in production; deliberate
  # invalid/retired SSO origins keep a token with no workspace grants.
  defp insert_fixture_grants(session, user, :magic_link, _opts) do
    members = Accounts.list_active_memberships_for_user(user)

    {:ok, _grants} =
      SessionGrants.insert_personal(Repo, session, %{
        grant_member_candidates: members,
        grant_accounts: Map.new(members, &{&1.account_id, &1.account})
      })
  end

  defp insert_fixture_grants(session, user, :sso, opts) do
    identity_id = opts[:user_identity_id]

    identity =
      if Repo.valid_uuid?(identity_id) do
        SSO.UserIdentity.Query.not_deleted()
        |> SSO.UserIdentity.Query.by_id(identity_id)
        |> Repo.peek()
      end

    if identity do
      Ecto.Multi.new()
      |> SSO.put_sign_in_authority(user, identity.account_id,
        user_identity_id: identity.id,
        provider_identifier: identity.provider_identifier
      )
      |> Ecto.Multi.run(:fixture_grants, fn repo, %{sso_destinations: destinations} ->
        SessionGrants.insert_sso(repo, session, destinations)
      end)
      |> Repo.commit_multi()
    end
  end

  defp insert_fixture_grants(_session, _user, _method, _opts), do: :ok
end
