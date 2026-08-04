defmodule Emisar.Auth do
  @moduledoc """
  Authentication: sign in/up flows, session tokens, magic links,
  password resets, email confirmation, MFA scaffold.

  All token types share `user_tokens` storage; `context` disambiguates
  semantics + validity window.
  """
  alias Ecto.Multi
  alias Emisar.{Accounts, Audit, Mailers}
  alias Emisar.Auth.MfaFacts
  alias Emisar.Auth.Role
  alias Emisar.Auth.SessionFacts
  alias Emisar.Auth.Subject
  alias Emisar.Auth.UserToken
  alias Emisar.Crypto
  alias Emisar.Repo
  alias Emisar.RequestContext
  alias Emisar.SSO
  alias Emisar.Telemetry
  alias Emisar.Throttle
  alias Emisar.Users
  require Logger

  # -- Role vocabulary --------------------------------------------------

  @doc "All assignable membership roles, most-privileged first."
  def roles, do: Role.all()

  @doc "Display label for a membership role (atom or string)."
  def role_label(role), do: Role.label(role)

  @doc "One-line description of what a membership role can do — `nil` when unknown."
  def role_description(role), do: Role.description(role)

  # -- Post-auth account target -----------------------------------------

  @doc """
  Internal — post-factor sign-in: decides which account a just-authenticated user
  lands on for a branded `/app/:account_id_or_slug` sign-in. The web boundary has
  already validated the local return path and extracted its account ref; the
  session token IS the credential being minted, so there's no Subject yet.

  Returns `:no_target` when the sign-in wasn't branded, `{:member, account}` when
  the user still holds a live membership on the target, `{:disabled, account}`
  when that account is disabled (its members are sent to the account's own
  sign-in page), and `:not_member` otherwise. An unknown ref, a non-member, a
  suspended or tombstoned membership, and a deleted account are all
  `:not_member` — a branded sign-in never confirms a tenant exists.
  """
  def resolve_post_auth_account(%Users.User{}, nil), do: :no_target

  def resolve_post_auth_account(%Users.User{} = user, account_ref) when is_binary(account_ref) do
    case Accounts.fetch_post_auth_membership(user, account_ref) do
      {:ok, %Accounts.Membership{account: %Accounts.Account{disabled_at: nil} = account}} ->
        {:member, account}

      {:ok, %Accounts.Membership{account: %Accounts.Account{} = account}} ->
        {:disabled, account}

      {:error, :not_found} ->
        :not_member
    end
  end

  # -- Session tokens ---------------------------------------------------

  @doc """
  Internal — SSO sign-in completion, the only remaining generic session minter
  and fixed to `:sso` provenance so no other flow can borrow it. Holds the
  active account row lock while recording the sign-in and inserting the
  user-global session credential, so a concurrent account disable either
  revokes this session afterward or prevents it from being minted. `mfa` says
  whether the IdP satisfies the second factor; `opts` carry the
  `:user_identity_id` the session is bound to. Returns `{:ok, token}` (the raw
  cookie value) or `{:error, :account_disabled | reason}`.
  """
  def complete_sso_account_sign_in(
        %Users.User{} = user,
        account_id,
        mfa,
        %RequestContext{} = context,
        opts \\ []
      ) do
    {token, digest} = Crypto.session_token()
    metadata = %{ip_address: context.ip_address, user_agent: context.user_agent}

    Multi.new()
    |> Multi.run(:account, fn repo, _changes ->
      case Accounts.fetch_and_lock_account(account_id, repo: repo) do
        {:ok, account} -> {:ok, account}
        {:error, :not_found} -> {:error, :account_disabled}
      end
    end)
    # An SSO session re-reads its connection HERE, under a lock held across the
    # insert below. The callback checked it too, but that lock is released when the
    # identity transaction commits — so a disable could commit, sweep no sessions,
    # and then this insert would add one that survives.
    |> Multi.run(:sso_provider, fn repo, _changes ->
      case SSO.ensure_identity_provider_enabled(repo, Keyword.get(opts, :user_identity_id)) do
        :ok -> {:ok, :enabled}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> Multi.merge(fn _changes ->
      Users.put_sign_in(Multi.new(), user, "sso", context)
    end)
    |> Multi.insert(:token, fn %{sign_in: signed_in_user} ->
      UserToken.Changeset.session(signed_in_user, digest, metadata, :sso, mfa, opts)
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, _changes} -> {:ok, token}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Internal — `EmisarWeb.UserAuth` resolves a request's session cookie to its
  user; the session token IS the credential, so there's no Subject yet.
  Returns `{:ok, user, token}` — the `%UserToken{}` rides alongside so the
  boundary reads its provenance (`auth_method` / `mfa` / `user_identity_id`)
  off it and stamps the `%Subject{}`. The user is preloaded scoped to live
  users, so a soft-deleted user's token resolves to `{:error, :not_found}` —
  as do expired / unknown / non-binary tokens.
  """
  def fetch_user_and_token_by_session_token(token) when is_binary(token) do
    UserToken.Query.by_token_digest(Crypto.hash(token))
    |> UserToken.Query.by_context("session")
    |> UserToken.Query.not_expired("session")
    |> UserToken.Query.with_valid_auth_method()
    |> UserToken.Query.with_preloaded_user()
    |> Repo.one()
    |> case do
      %UserToken{user: %Users.User{} = user} = token -> {:ok, user, token}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Internal — FORCED invalidation of the session row behind a cookie (the
  suspended-account bounce, the require_sso step-up); possession of the cookie
  value IS the authorization, so no Subject. Deliberately writes no
  `user.signed_out` audit: that event means the operator CHOSE to sign out and
  belongs to `complete_session_sign_out/2`.
  """
  def delete_session_token(token) when is_binary(token) do
    UserToken.Query.by_token_digest(Crypto.hash(token))
    |> UserToken.Query.by_context("session")
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Internal — the normal, VOLUNTARY sign-out: `EmisarWeb.UserAuth` presents the
  raw cookie value and the domain ends that session. Possession of the cookie IS
  the authorization, so no Subject — and the actor is read off the token row, so
  the audit names whoever the credential belongs to rather than the boundary's
  own snapshot of who is signed in.

  The row delete and `user.signed_out` commit together, so a browser is never
  told it signed out on a transaction that rolled back. The audit lands only for
  a session that was actually live — inside its window, valid auth method, live
  user — and only when exactly one row was deleted, so a double-submitted
  sign-out serializes on the token lock and audits once. Expired,
  removed-auth-method, and soft-deleted-user rows are still swept, silently.

  Returns `:ok`, including for an unknown or stale token, or `{:error, reason}`
  when the transaction fails.
  """
  def complete_session_sign_out(token, context \\ %RequestContext{}) when is_binary(token) do
    digest = Crypto.hash(token)

    live_session_query =
      UserToken.Query.by_token_digest(digest)
      |> UserToken.Query.by_context("session")
      |> UserToken.Query.not_expired("session")
      |> UserToken.Query.with_valid_auth_method()
      |> UserToken.Query.with_preloaded_user()
      |> UserToken.Query.lock_for_update()

    stored_session_query =
      UserToken.Query.by_token_digest(digest)
      |> UserToken.Query.by_context("session")

    Multi.new()
    |> Multi.run(:session_user, fn repo, _changes ->
      case repo.peek(live_session_query) do
        %UserToken{user: %Users.User{} = user} -> {:ok, user}
        _dead_or_missing -> {:ok, nil}
      end
    end)
    |> Multi.delete_all(:sessions, stored_session_query)
    |> Audit.Multi.log_for_user(:audit, nil, "user.signed_out",
      extra: [context: context],
      user_fn: fn %{session_user: user, sessions: {count, _}} ->
        if count == 1, do: user
      end
    )
    |> Repo.commit_multi()
    |> case do
      {:ok, _changes} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Internal — `EmisarWeb.UserAuth` (and sibling revoke-all paths) calls this
  for the user already resolved from their session, so no Subject. Deletes
  every session token for the user. Returns `{:ok, count}` so a caller can
  compose it into its own transaction via `Multi.run` (the team-admin "sign
  out everywhere" does) — token internals stay private to Auth.
  """
  def delete_all_session_tokens(%Users.User{} = user) do
    {count, _} =
      UserToken.Query.by_user_id(user.id)
      |> UserToken.Query.by_context("session")
      |> Repo.delete_all()

    {:ok, count}
  end

  @doc """
  Internal — an account ending its own hold on a user: revoke the sessions
  authenticated through `identity_ids` (that account's SSO connections) and
  disconnect every live socket the user holds.

  A session token is per-user, not per-account, so revoking them ALL signed the
  person out of every other account they belong to — one tenant's directory
  reaching into another's browser. Only the credentials bound to this account's
  connections are destroyed. The broad disconnect is not a logout: each socket
  re-mounts and re-resolves its membership, which is what actually ends access to
  the suspended account, and leaves the others signed in.
  """
  def revoke_identity_sessions(%Users.User{} = user, identity_ids) when is_list(identity_ids) do
    topics = live_socket_topics_for_user(user)

    queryable =
      UserToken.Query.by_user_id(user.id)
      |> UserToken.Query.by_context("session")
      |> UserToken.Query.by_user_identity_ids(identity_ids)

    Repo.delete_all(queryable)
    disconnect_live_sessions(topics)
    :ok
  end

  @doc """
  Live-session terminator for "user must lose access RIGHT NOW" paths
  (admin suspend, force-password-reset, account-wide password change).
  Captures every active LiveView topic, deletes the underlying token rows,
  then broadcasts the captured topics — so a socket that subscribes during
  revocation still receives its disconnect after its credential is dead.

  Pair with the standard `delete_all_session_tokens/1` for the auth
  cookie invalidation; the broadcast is best-effort and idempotent.
  """
  def disconnect_and_revoke_all_sessions(%Users.User{} = user) do
    topics = live_socket_topics_for_user(user)
    {:ok, count} = delete_all_session_tokens(user)
    if count > 0, do: disconnect_live_sessions(topics)
    :ok
  end

  @doc """
  "Sign out everywhere except this device" — kills every session except
  the one carrying `keep_token` (the caller's current cookie) AND
  broadcasts a disconnect to each of those sessions' LiveView sockets.
  Returns the count of sessions terminated.

  Self-service only: the user signing out is the subject's own actor, so
  it's read from the `%Subject{}` rather than passed separately — there's
  no way to revoke anyone else's sessions through this path.
  """
  def revoke_and_disconnect_other_sessions!(
        keep_token,
        %Subject{actor: %Users.User{} = user} = subject
      )
      when is_binary(keep_token) do
    keep_digest = Crypto.hash(keep_token)
    topics = live_socket_topics_for_user(user, except: keep_digest)
    count = revoke_other_sessions!(user, keep_token, subject.context)
    if count > 0, do: disconnect_live_sessions(topics)
    count
  end

  @doc """
  Internal — fan-out helper for Auth's own session-revocation paths (no
  user-facing caller), so the already-resolved user is passed, not a Subject.
  Broadcasts a per-session "disconnect" message to every active
  session for `user`, optionally skipping the session whose token
  digest matches `except:` (used by "sign out everywhere else" to
  keep the caller's tab alive).

  Pure side-effect — does NOT delete tokens from the DB. Pair with
  `delete_all_session_tokens/1` or a transactional delete when you
  also want to invalidate the cookies on the server side.

  The actual PubSub broadcast lives in `EmisarWeb.SessionDisconnector`
  (configured via `:emisar, :session_disconnect_handler`) because
  `%Phoenix.Socket.Broadcast{}` — the struct Phoenix.LiveView listens
  for — lives in the `phoenix` package, which the data-layer app
  deliberately doesn't depend on. Auth knows WHICH topics to kill;
  the web app knows HOW to broadcast.
  """
  def broadcast_disconnect_for_user(%Users.User{} = user, opts \\ []) do
    user
    |> live_socket_topics_for_user(opts)
    |> disconnect_live_sessions()

    :ok
  end

  defp live_socket_topics_for_user(%Users.User{} = user, opts \\ []) do
    skip_digest = Keyword.get(opts, :except)

    UserToken.Query.by_user_id(user.id)
    |> UserToken.Query.by_context("session")
    |> Repo.all()
    |> Enum.reject(&(&1.token == skip_digest))
    |> Enum.map(&live_socket_topic(&1.token))
  end

  defp disconnect_live_sessions(topics) do
    # The handler module lives in `emisar_web` — `Code.ensure_loaded?`
    # is defensive against running this code in an `:emisar`-only test
    # process where the umbrella sibling hasn't been started.
    handler = Application.get_env(:emisar, :session_disconnect_handler)

    if handler && Code.ensure_loaded?(handler) do
      handler.disconnect_live_sessions(topics)
    end

    :ok
  end

  @doc """
  Topic name the LiveView socket subscribes to for "this specific
  session was killed" disconnects. Keyed off the digest stored on the
  user_tokens row so the topic can be derived from server-side state
  (the raw cookie value is only available to the user's own browser).
  """
  def live_socket_topic(token_digest) when is_binary(token_digest),
    do: "users_sessions:#{Crypto.encode_digest(token_digest)}"

  @doc """
  Same topic derived from the RAW session token — for the sign-in
  boundary, which holds the cookie value and shouldn't compute digests
  itself.
  """
  def live_socket_topic_for_session(token) when is_binary(token),
    do: live_socket_topic(Crypto.hash(token))

  @doc """
  The caller's own active sessions, newest first (Profile's device list).
  Self-service — the user is the subject's own actor, so the list spans every
  workspace they belong to, exactly like the identity it describes.

  `presented_token` is the caller's own raw session token: it is hashed once
  here and each stored digest is compared against it in constant time, so the
  row making this request comes back `current?: true` and no caller has to
  handle a digest to find it. A `nil` (or otherwise non-binary) token simply
  marks every row `current?: false`.

  Rows project into `%SessionFacts{}` — no token, no digest, no raw metadata —
  so the device list cannot leak credential material. Returns `{:ok,
  [%SessionFacts{}], %Paginator.Metadata{}}`, or `{:error, :unauthorized}` for
  a non-user subject.
  """
  def list_sessions_for_user(presented_token, subject, opts \\ [])

  def list_sessions_for_user(presented_token, %Subject{actor: %Users.User{} = user}, opts) do
    presented_digest = presented_session_digest(presented_token)

    sessions_query =
      UserToken.Query.by_user_id(user.id)
      |> UserToken.Query.by_context("session")
      |> UserToken.Query.with_valid_auth_method()

    case Repo.list(sessions_query, UserToken.Query, opts) do
      {:ok, tokens, metadata} ->
        {:ok, Enum.map(tokens, &session_facts(&1, presented_digest)), metadata}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def list_sessions_for_user(_presented_token, %Subject{}, _opts), do: {:error, :unauthorized}

  defp presented_session_digest(token) when is_binary(token), do: Crypto.hash(token)
  defp presented_session_digest(_token), do: nil

  defp session_facts(%UserToken{} = token, presented_digest) do
    %SessionFacts{
      id: token.id,
      current?: current_session?(token.token, presented_digest),
      ip_address: session_metadata(token.metadata, "ip_address"),
      user_agent: session_metadata(token.metadata, "user_agent"),
      inserted_at: token.inserted_at
    }
  end

  defp current_session?(_digest, nil), do: false

  defp current_session?(digest, presented_digest),
    do: Crypto.secure_compare(digest, presented_digest)

  # Only the two display keys the device list renders, and only when the stored
  # value is a string — session metadata is written at the web boundary, so the
  # projection never hands a surface a shape it didn't ask for.
  defp session_metadata(metadata, key) when is_map(metadata) do
    case Map.get(metadata, key) do
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  defp session_metadata(_metadata, _key), do: nil

  @doc """
  Revoke one of the caller's own sessions by id (Profile's per-device
  sign-out). Self-service — the user comes from the subject's own
  actor, and the query is scoped to them so a malicious id can't kill
  another user's session. Returns :ok | {:error, :not_found}.
  """
  def revoke_session(token_id, %Subject{actor: %Users.User{} = user} = subject) do
    if Repo.valid_uuid?(token_id) do
      session_query =
        UserToken.Query.by_id(token_id)
        |> UserToken.Query.by_user_id(user.id)
        |> UserToken.Query.by_context("session")

      Multi.new()
      |> Multi.delete_all(:sessions, session_query)
      |> Multi.run(:check_affected, fn _repo, %{sessions: {affected, _}} ->
        if affected == 1, do: {:ok, :revoked}, else: {:error, :not_found}
      end)
      |> Audit.Multi.log_for_user(:audit, user, "user.session_revoked",
        extra: [context: subject.context],
        payload_fn: fn _ -> %{session_id: token_id} end
      )
      |> Repo.commit_multi()
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Internal — the token-deletion half of
  `revoke_and_disconnect_other_sessions!/2` (the Subject-fronted public
  surface): revoke every session except the one carrying `keep_token`.
  Pass `nil` to revoke every session including the current one.
  """
  def revoke_other_sessions!(user, keep_token, context \\ %RequestContext{})

  def revoke_other_sessions!(%Users.User{} = user, keep_token, context)
      when is_binary(keep_token) do
    sessions_query =
      UserToken.Query.by_user_id(user.id)
      |> UserToken.Query.by_context("session")
      |> UserToken.Query.except_token_digest(Crypto.hash(keep_token))

    revoke_sessions_atomically!(user, sessions_query, context)
  end

  def revoke_other_sessions!(%Users.User{} = user, nil, context) do
    sessions_query =
      UserToken.Query.by_user_id(user.id)
      |> UserToken.Query.by_context("session")

    revoke_sessions_atomically!(user, sessions_query, context)
  end

  # Wraps the delete + (conditional) audit in one transaction so a row
  # delete-without-audit can't happen on a downstream failure. The
  # audit's `user_fn` resolves the user only when rows were actually
  # revoked — a no-op revoke stays out of the log.
  defp revoke_sessions_atomically!(%Users.User{} = user, sessions_query, context) do
    {:ok, %{count: count}} =
      Multi.new()
      |> Multi.delete_all(:sessions, sessions_query)
      |> Multi.run(:count, fn _repo, %{sessions: {count, _}} -> {:ok, count} end)
      |> Audit.Multi.log_for_user(:audit, user, "user.other_sessions_revoked",
        extra: [context: context],
        user_fn: fn %{count: count} -> if count > 0, do: user end,
        payload_fn: fn %{count: count} -> %{count: count} end
      )
      |> Repo.commit_multi()

    count
  end

  # -- Magic link -------------------------------------------------------

  # Shared prefix of the single-use token flows (magic link / password
  # reset / confirm): locks the still-valid token row, then resolves its
  # user — both inside the transaction, so a double-submitted link
  # serializes on the row lock and the loser sees the token already
  # gone instead of raising a stale-delete.
  defp verified_token_multi(digest, context) do
    Multi.new()
    |> Multi.run(:token, fn repo, _changes ->
      loaded_token =
        UserToken.Query.by_token_digest(digest)
        |> UserToken.Query.by_context(context)
        |> UserToken.Query.not_expired(context)
        |> UserToken.Query.lock_for_update()
        |> repo.one()

      if loaded_token, do: {:ok, loaded_token}, else: {:error, :invalid_or_expired}
    end)
    |> Multi.run(:token_user, fn _repo, %{token: token} ->
      case Users.fetch_user_by_id(token.user_id) do
        {:ok, user} ->
          {:ok, user}

        # A soft-deleted user behind a still-live token is the same
        # outcome for the caller: the link no longer works.
        {:error, :not_found} ->
          {:error, :invalid_or_expired}
      end
    end)
  end

  # Online-guess budget for the alphanumeric magic-link secret. The nonce carries
  # the real entropy; this caps brute-force by anyone who somehow has it.
  @magic_link_attempts 5

  @doc """
  Internal — pre-auth: the whole magic-link request. Issues a split-code token
  and emails the code + link; the raw secret never leaves Auth, so no caller can
  relay a sign-in credential it didn't earn. The link IS the factor being minted,
  so there's no Subject yet.

  Options: `:account_ref` — the branded `/app/:account_id_or_slug` target the
  request came from, or `nil` for an unbranded sign-in; a disabled, deleted,
  unknown, or malformed ref is `{:error, :not_found}` and issues + sends nothing.
  `:return_to` — the already-validated local path carried into the emailed link.

  Returns `{:ok, %{token_id: id, nonce: nonce, delivery: delivery}}` — the caller
  keeps `nonce` browser-side (a short-lived cookie) — where `delivery` is
  `{:ok, :sent}`, `{:ok, :suppressed}` (the address bounced or was marked spam,
  so nothing was sent), or `{:error, reason}`.
  """
  def request_magic_link(%Users.User{} = user, %RequestContext{} = context, opts \\ []) do
    with :ok <- ensure_magic_link_account(Keyword.get(opts, :account_ref)) do
      issue_and_deliver_magic_link(user, context, Keyword.get(opts, :return_to))
    end
  end

  defp ensure_magic_link_account(nil), do: :ok

  defp ensure_magic_link_account(account_ref) when is_binary(account_ref) do
    with {:ok, _account} <- Accounts.fetch_account_by_id_or_slug(account_ref), do: :ok
  end

  defp ensure_magic_link_account(_account_ref), do: {:error, :not_found}

  # The token + its audit row commit before the send, so the email is a
  # post-commit side effect the caller reports on rather than a step that can
  # undo an issued factor — a mailer outage must not leave the audit log
  # claiming a link that no longer exists.
  defp issue_and_deliver_magic_link(%Users.User{} = user, context, return_to) do
    {token_id, nonce, secret} = issue_magic_link(user, context)

    delivery =
      case Mailers.UserNotifier.deliver_magic_link(user, token_id, secret, context, return_to) do
        {:ok, %{suppressed: true}} -> {:ok, :suppressed}
        {:ok, _sent} -> {:ok, :sent}
        {:error, reason} -> {:error, reason}
      end

    {:ok, %{token_id: token_id, nonce: nonce, delivery: delivery}}
  end

  # Mints the split-code token: the caller keeps `nonce` browser-side, the
  # `secret` (a short alphanumeric code) is emailed alongside a link carrying
  # `token_id` + `secret`. Deletes any prior outstanding magic-link token for the
  # user (single outstanding). Private — the raw secret stays inside Auth.
  defp issue_magic_link(%Users.User{} = user, context) do
    {nonce, secret, digest} = Crypto.magic_link_token()

    prior =
      UserToken.Query.by_user_id(user.id)
      |> UserToken.Query.by_context("magic_link")

    {:ok, %{token: token}} =
      Multi.new()
      |> Multi.delete_all(:prior, prior)
      |> Multi.insert(
        :token,
        UserToken.Changeset.magic_link(user, digest, user.email, @magic_link_attempts)
      )
      |> Audit.Multi.log_for_user(:audit, user, "user.magic_link_issued",
        extra: [context: context]
      )
      |> Repo.commit_multi()

    {token.id, nonce, secret}
  end

  @doc """
  Internal — signup email correction from the same browser that requested a
  registration magic link for this exact user. Applies the corrected address,
  then issues and emails a fresh link to it; a correction carries no branded
  return path. Returns the same narrowed `{:ok, %{token_id: id, nonce: nonce,
  delivery: delivery}}` as `request_magic_link/3`, or `{:error,
  :invalid_or_expired | :already_confirmed | %Ecto.Changeset{}}`.
  """
  def correct_registration_email(
        token_id,
        registration_user_id,
        new_email,
        context \\ %RequestContext{}
      )
      when is_binary(token_id) and is_binary(registration_user_id) and is_binary(new_email) do
    with {:ok, %UserToken{user: %Users.User{} = user}} <-
           fetch_live_magic_link_token(token_id),
         :ok <- ensure_registration_token_user(user, registration_user_id),
         {:ok, %Users.User{} = updated} <-
           Users.correct_unconfirmed_user_email(user.id, new_email, context: context) do
      issue_and_deliver_magic_link(updated, context, nil)
    end
  end

  @doc "Validity window of a magic-link code, in minutes — for the sent-page countdown."
  def magic_link_validity_in_minutes, do: UserToken.Query.magic_link_validity_in_minutes()

  @doc """
  Verifies a split-code magic link by reconstructing `hash(nonce <> secret)` and
  matching it against the locked token row. BOTH halves are required, so an
  intercepted email link/code can't sign in without the originating browser's
  nonce. Single-use on success; a wrong half spends one of the #{@magic_link_attempts}
  attempts, and a spent-out or expired token reads as `{:error, :invalid_or_expired}`.
  """
  def verify_magic_link(token_id, secret, nonce, context \\ %RequestContext{})
      when is_binary(token_id) and is_binary(secret) and is_binary(nonce) do
    if Repo.valid_uuid?(token_id) do
      verify_live_magic_link(token_id, secret, nonce, context)
    else
      record_magic_link_failure(token_id, :invalid_or_expired, context)
    end
  end

  defp verify_live_magic_link(token_id, secret, nonce, context) do
    Multi.new()
    |> Multi.run(:token, fn repo, _changes ->
      loaded_token =
        UserToken.Query.by_id(token_id)
        |> UserToken.Query.by_context("magic_link")
        |> UserToken.Query.not_expired("magic_link")
        |> UserToken.Query.with_attempts_remaining()
        |> UserToken.Query.lock_for_update()
        |> repo.one()

      if loaded_token, do: {:ok, loaded_token}, else: {:error, :invalid_or_expired}
    end)
    |> Multi.run(:outcome, fn repo, %{token: token} ->
      if Crypto.secure_compare(Crypto.magic_link_digest(nonce, secret), token.token) do
        # Both halves match → single-use: delete the token, resolve the user.
        {:ok, _} = repo.delete(token)

        case Users.fetch_user_by_id(token.user_id) do
          # Completing the emailed code IS proof of inbox ownership — an
          # unconfirmed user is confirmed here, so the "verify your email"
          # banner can't nag someone who just authenticated via that inbox.
          # Audited like the link path (user.email_confirmed, method noted).
          {:ok, %Users.User{confirmed_at: nil} = user} ->
            {:ok, confirmed} = Users.mark_user_confirmed(user)

            :ok =
              Audit.log_for_user(confirmed, "user.email_confirmed",
                payload: %{method: "magic_link"},
                context: context
              )

            {:ok, {:ok, confirmed}}

          {:ok, user} ->
            {:ok, {:ok, user}}

          # A soft-deleted user behind a live token reads as a dead link.
          {:error, :not_found} ->
            {:ok, {:error, :invalid_or_expired}}
        end
      else
        # Wrong nonce or secret → spend one attempt. Returns `{:ok, …}` so the
        # decrement COMMITS (a Multi rollback would undo the spend).
        {:ok, _} = repo.update(UserToken.Changeset.decrement_attempts(token))
        {:ok, {:error, :invalid_or_expired}}
      end
    end)
    # No success audit here — verifying a factor is NOT signing in. The session
    # layer's `Users.record_sign_in/3` is the ONE writer of `user.signed_in`,
    # fired when a session is actually established (after MFA, when required);
    # auditing here too double-wrote every login and stamped "signed in" for
    # MFA logins that never completed factor two. Failures still audit below.
    |> Repo.commit_multi()
    |> case do
      {:ok, %{outcome: {:ok, %Users.User{} = user}}} ->
        {:ok, user}

      # Digest mismatch / soft-deleted user (the Multi committed the attempt spend).
      {:ok, %{outcome: {:error, reason}}} ->
        record_magic_link_failure(token_id, reason, context)

      # The token step rolled back — token missing / expired / spent-out.
      {:error, reason} ->
        record_magic_link_failure(token_id, reason, context)
    end
  end

  # A magic-link sign-in failed. `user.sign_in_failed` is account-scoped, so it
  # only lands when the token still resolves to a real user (a live token with a
  # bad secret, or an expired/spent one that wasn't deleted). A consumed or
  # undecodable token has no user to attribute — logged + counted server-side
  # instead, with the SAME `{:error, :invalid_or_expired}` return so the response
  # can't be turned into an email-enumeration oracle. Always returns the error.
  defp record_magic_link_failure(token_id, reason, context) do
    case peek_magic_link_user(token_id) do
      {:ok, %Users.User{} = user} ->
        Audit.log_for_user(user, "user.sign_in_failed",
          payload: %{reason: reason, method: "magic_link"},
          context: context
        )

      :error ->
        Logger.warning("magic-link sign-in failed for an unresolvable token")
        Telemetry.magic_link_failed(reason)
    end

    {:error, reason}
  end

  # Resolve the user behind a magic-link token id WITHOUT the expiry/attempts
  # filters, so a failed (expired / spent) token still attributes to its owner.
  defp peek_magic_link_user(token_id) do
    if Repo.valid_uuid?(token_id) do
      queryable =
        UserToken.Query.by_id(token_id)
        |> UserToken.Query.by_context("magic_link")

      with %UserToken{} = token <- Repo.peek(queryable),
           {:ok, user} <- Users.fetch_user_by_id(token.user_id) do
        {:ok, user}
      else
        _ -> :error
      end
    else
      :error
    end
  end

  defp fetch_live_magic_link_token(token_id) do
    if Repo.valid_uuid?(token_id) do
      token =
        UserToken.Query.by_id(token_id)
        |> UserToken.Query.by_context("magic_link")
        |> UserToken.Query.not_expired("magic_link")
        |> UserToken.Query.with_attempts_remaining()
        |> UserToken.Query.with_preloaded_user()
        |> Repo.peek()

      case token do
        %UserToken{user: %Users.User{}} = token -> {:ok, token}
        _ -> {:error, :invalid_or_expired}
      end
    else
      {:error, :invalid_or_expired}
    end
  end

  defp ensure_registration_token_user(%Users.User{id: user_id}, registration_user_id) do
    if Repo.valid_uuid?(registration_user_id) and user_id == registration_user_id,
      do: :ok,
      else: {:error, :invalid_or_expired}
  end

  # -- Magic-link sign-in completion ------------------------------------

  @mfa_sign_in_proof_salt "mfa sign-in proof"
  @mfa_sign_in_proof_max_age_seconds 120

  @doc """
  Internal — factor one is done (a magic link verified inbox possession) and the
  boundary asks the domain to finish the sign-in; the session token IS the
  credential being minted, so there's no Subject yet. `account_ref` is the
  already-validated branded `/app/:account_id_or_slug` target, or `nil`.

  The user is re-read HERE, never taken from the caller, so an enrollment that
  landed since the link was issued still forces the second factor; the same
  check runs again on the locked row inside the minting transaction. The
  session's provenance is fixed — `:magic_link` with `mfa: false` — so no caller
  can claim a factor it didn't verify.

  Returns `{:ok, user, token, target}` — `user` is the row the minting
  transaction locked and stamped, so the boundary installs the session for the
  state the domain actually signed in rather than its own earlier snapshot, and
  `target` is `{:member, account}`, `:not_member`, or `:no_target` (what the
  boundary routes on). `{:error, :mfa_required}` when the second factor is still
  owed, `{:error, {:account_disabled, account}}` when the branded account is on
  hold, or `{:error, :not_found}` when the user no longer resolves.
  """
  def complete_magic_link_sign_in(user_id, account_ref, %RequestContext{} = context) do
    with {:ok, user} <- Users.fetch_user_by_id(user_id),
         :ok <- ensure_mfa_state_current(user, nil) do
      target = resolve_post_auth_account(user, account_ref)

      complete_sign_in_for_target(target, &insert_magic_link_session(user, &1, nil, context))
    end
  end

  @doc """
  Internal — factor two is done: `proof` is the opaque term `verify_mfa_challenge/3`
  returned, and this mints the full session for it. `account_ref` is the
  already-validated branded target, or `nil`.

  The proof is re-checked against the LOCKED user row before anything is
  written, so it is only good for the enrollment it was minted against: a
  disable, a re-enable, a secret rotation, or any other credential write since
  the challenge fails closed with no token. Provenance is fixed to `:magic_link`
  with `mfa: true`.

  Same `{:ok, user, token, target}` success shape as
  `complete_magic_link_sign_in/3`; `{:error, :mfa_proof_stale}` when the proof no
  longer matches the row — including a replay of a proof that already completed,
  since minting stamps the sign-in and moves `updated_at` on — `{:error,
  {:account_disabled, account}}`, or `{:error, :not_found}`.
  """
  def complete_magic_link_mfa_sign_in(proof, account_ref, %RequestContext{} = context) do
    with {:ok, user} <- Users.fetch_user_by_id(mfa_proof_user_id(proof)) do
      target = resolve_post_auth_account(user, account_ref)

      complete_sign_in_for_target(target, &insert_magic_link_session(user, &1, proof, context))
    end
  end

  # A disabled branded account never mints a session — its members are sent to
  # that account's own sign-in page, so the boundary needs the account back.
  defp complete_sign_in_for_target({:disabled, %Accounts.Account{} = account}, _mint),
    do: {:error, {:account_disabled, account}}

  defp complete_sign_in_for_target({:member, %Accounts.Account{} = account} = target, mint) do
    case mint.(account) do
      {:ok, user, token} -> {:ok, user, token, target}
      {:error, :account_disabled} -> {:error, {:account_disabled, account}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp complete_sign_in_for_target(target, mint) do
    case mint.(nil) do
      {:ok, user, token} -> {:ok, user, token, target}
      {:error, reason} -> {:error, reason}
    end
  end

  # The ONE magic-link session minter. `proof` is `nil` for a factor-one
  # completion and a verified MFA proof for factor two — it fixes BOTH the
  # re-check on the locked user row AND the `mfa` provenance stamped on the
  # token, so the two can't disagree and no caller supplies either.
  #
  # Locks the branded account first and the user row second — one ordering for
  # both factors, so concurrent completions can't deadlock — and holds both
  # across the insert, so a disable committed mid-sign-in either revokes this
  # session afterward or prevents it from being minted.
  #
  # Returns the sign-in-stamped row from that transaction, never the caller's
  # snapshot: the boundary installs the session against the state the domain
  # actually signed in.
  defp insert_magic_link_session(
         %Users.User{} = user,
         account,
         proof,
         %RequestContext{} = context
       ) do
    {token, digest} = Crypto.session_token()
    metadata = %{ip_address: context.ip_address, user_agent: context.user_agent}

    Multi.new()
    |> lock_sign_in_account(account)
    |> Multi.run(:user, fn repo, _changes ->
      lock_signing_in_user(user.id, proof, repo)
    end)
    |> Multi.merge(fn %{user: loaded_user} ->
      Users.put_sign_in(Multi.new(), loaded_user, "magic_link", context)
    end)
    |> Multi.insert(:token, fn %{sign_in: signed_in_user} ->
      UserToken.Changeset.session(
        signed_in_user,
        digest,
        metadata,
        :magic_link,
        not is_nil(proof)
      )
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{sign_in: signed_in_user}} -> {:ok, signed_in_user, token}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_sign_in_account(multi, nil), do: multi

  defp lock_sign_in_account(multi, %Accounts.Account{id: account_id}) do
    Multi.run(multi, :account, fn repo, _changes ->
      case Accounts.fetch_and_lock_account(account_id, repo: repo) do
        {:ok, account} -> {:ok, account}
        {:error, :not_found} -> {:error, :account_disabled}
      end
    end)
  end

  defp lock_signing_in_user(user_id, proof, repo) do
    with {:ok, loaded_user} <- Users.fetch_and_lock_user_by_id(user_id, repo),
         :ok <- ensure_mfa_state_current(loaded_user, proof) do
      {:ok, loaded_user}
    end
  end

  # Factor one against an enrolled user is unfinished business, not a session.
  defp ensure_mfa_state_current(%Users.User{mfa_enabled_at: %DateTime{}}, nil),
    do: {:error, :mfa_required}

  defp ensure_mfa_state_current(%Users.User{}, nil), do: :ok

  defp ensure_mfa_state_current(%Users.User{} = user, proof) do
    with {:ok, payload} <- verify_mfa_proof(proof),
         true <- payload == mfa_proof_payload(user) do
      :ok
    else
      _ -> {:error, :mfa_proof_stale}
    end
  end

  # -- Email-change step-up --------------------------------------------

  # Online-guess budget for the 6-digit email-change step-up code.
  @email_change_attempts 5

  @doc """
  Mints + emails a 6-digit step-up code to the user's CURRENT address, binding
  it to `new_email`. A self-service email change must re-enter it first, so the
  identity-defining field (it controls every future magic link) gets a
  credential-grade gate a stolen session alone can't pass. Deletes any prior
  outstanding email-change code (single outstanding). Best-effort delivery;
  returns `:ok` or `{:error, :not_found}`.
  """
  def issue_email_change_code(new_email, %Subject{actor: %Users.User{id: id}} = subject)
      when is_binary(new_email) do
    with {:ok, user} <- Users.fetch_user_by_id(id) do
      do_issue_email_change_code(new_email, user, subject)
    end
  end

  defp do_issue_email_change_code(
         new_email,
         %Users.User{} = user,
         %Subject{} = subject
       ) do
    {code, digest} = Crypto.email_change_code()

    prior =
      UserToken.Query.by_user_id(user.id)
      |> UserToken.Query.by_context("email_change")

    {:ok, _} =
      Multi.new()
      |> Multi.delete_all(:prior, prior)
      |> Multi.insert(
        :token,
        UserToken.Changeset.email_change(user, digest, new_email, @email_change_attempts)
      )
      |> Audit.Multi.log_for_user(:audit, user, "user.email_change_requested",
        extra: [context: subject.context]
      )
      |> Repo.commit_multi()

    _ = Mailers.UserNotifier.deliver_email_change_code(user, code)
    :ok
  end

  @doc """
  Verifies an email-change step-up code against the user's locked `email_change`
  token. Returns `{:ok, new_email}` — the email the code was bound to, for the
  caller to pass straight to `Users.update_user_email/2` — on a match
  (single-use: the token is consumed), or `{:error, :invalid}` for a
  wrong/expired/spent code (a wrong code spends one of the #{@email_change_attempts}
  attempts).
  """
  def verify_email_change_code(code, %Subject{actor: %Users.User{} = user})
      when is_binary(code) do
    Multi.new()
    |> Multi.run(:token, fn repo, _changes ->
      loaded_token =
        UserToken.Query.by_user_id(user.id)
        |> UserToken.Query.by_context("email_change")
        |> UserToken.Query.not_expired("email_change")
        |> UserToken.Query.with_attempts_remaining()
        |> UserToken.Query.lock_for_update()
        |> repo.one()

      if loaded_token, do: {:ok, loaded_token}, else: {:error, :invalid}
    end)
    |> Multi.run(:outcome, fn repo, %{token: token} ->
      if Crypto.secure_compare(Crypto.hash(code), token.token) do
        # Match → single-use: consume the token, hand back the bound email.
        {:ok, _} = repo.delete(token)
        {:ok, {:ok, token.sent_to}}
      else
        # Wrong code → spend one attempt. `{:ok, …}` so the decrement COMMITS.
        {:ok, _} = repo.update(UserToken.Changeset.decrement_attempts(token))
        {:ok, {:error, :invalid}}
      end
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{outcome: outcome}} -> outcome
      {:error, _} -> {:error, :invalid}
    end
  end

  @doc """
  Begin a self-service email change: the DOMAIN decides the step-up factor from
  the user's CURRENT row — an MFA user re-enters TOTP (`:totp`), otherwise a
  one-time code is emailed to the current address to prove inbox control
  (`:code`, issued here). Returns `{:ok, :totp | :code}`. The factor is the
  domain's call so a stale MFA snapshot in the caller can't downgrade the
  challenge, and `confirm_email_change/3` re-derives it the same way.
  """
  def begin_email_change(new_email, %Subject{actor: %Users.User{id: id}} = subject)
      when is_binary(new_email) do
    with {:ok, user} <- Users.fetch_user_by_id(id) do
      case email_change_factor(user) do
        :totp ->
          {:ok, :totp}

        :code ->
          :ok = do_issue_email_change_code(new_email, user, subject)
          {:ok, :code}
      end
    end
  end

  @doc """
  Confirm a self-service email change: re-derive the required factor from the
  user's CURRENT row, verify `code` against it (TOTP for an MFA user, the emailed
  one-time code otherwise), and only on success apply the new email. The commit is
  gated on a domain-verified step-up HERE — `update_user_email` is never reached
  without it, so the web decides nothing. `{:ok, user} | {:error, :invalid |
  :replay | :rate_limited | %Ecto.Changeset{}}` — the TOTP branch spends an
  attempt from the shared per-user MFA window, so it is `:rate_limited` once that
  window is exhausted (the emailed-code branch has its own single-use token).
  """
  def confirm_email_change(new_email, code, %Subject{actor: %Users.User{id: id}} = subject)
      when is_binary(new_email) and is_binary(code) do
    with {:ok, user} <- Users.fetch_user_by_id(id),
         {:ok, email} <- verify_email_change_step_up(user, new_email, code, subject) do
      Users.update_user_email(email, subject)
    end
  end

  defp email_change_factor(%Users.User{mfa_enabled_at: %DateTime{}}), do: :totp
  defp email_change_factor(%Users.User{}), do: :code

  # MFA-on: the TOTP second factor stands in for re-auth; the requested email is
  # applied. MFA-off: the emailed code proves current-inbox control AND binds the
  # target email (the applied email is the token's, not the caller's).
  defp verify_email_change_step_up(
         %Users.User{mfa_enabled_at: %DateTime{}} = user,
         new_email,
         code,
         subject
       ) do
    with {:ok, _verified} <- verify_mfa(user, code, subject.context), do: {:ok, new_email}
  end

  defp verify_email_change_step_up(%Users.User{}, _new_email, code, subject) do
    verify_email_change_code(code, subject)
  end

  # -- Email confirmation ----------------------------------------------

  @doc "Internal — the email-confirmation flow (registration / pre-auth) mints the confirm token; no Subject yet."
  def issue_confirmation_token!(%Users.User{} = user) do
    {raw, digest} = Crypto.email_token()
    Repo.insert!(UserToken.Changeset.hashed(user, digest, "confirm", user.email))
    raw
  end

  @doc """
  Issues a fresh confirmation token and emails the confirm link. The one
  place "send a confirmation email" lives — sign-up, the Team-page resend,
  and the portal banner all call this so the token + delivery never drift.
  Best-effort: returns `:ok` regardless of the mailer result.
  """
  def deliver_confirmation_instructions(%Users.User{} = user) do
    token = issue_confirmation_token!(user)
    _ = Mailers.UserNotifier.deliver_confirmation_instructions(user, token)
    :ok
  end

  def confirm_user_by_token(raw, context \\ %RequestContext{}) when is_binary(raw) do
    case Crypto.email_token_digest(raw) do
      :error ->
        {:error, :invalid_or_expired}

      {:ok, digest} ->
        verified_token_multi(digest, "confirm")
        |> Multi.run(:user, fn _repo, %{token_user: user} -> Users.mark_user_confirmed(user) end)
        |> Multi.delete(:deleted_token, fn %{token: token} -> token end)
        |> Audit.Multi.log_for_user(:audit, nil, "user.email_confirmed",
          extra: [context: context],
          user_fn: fn %{user: user} -> user end
        )
        |> Repo.commit_multi()
        |> case do
          {:ok, %{user: confirmed}} -> {:ok, confirmed}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # -- MFA scaffold -----------------------------------------------------

  @doc """
  The caller's own second-factor state for display: is TOTP on, and how many
  recovery codes are left. Self-service — the subject's actor snapshot IS the
  answer, so this reads no rows and never surfaces the TOTP secret or the
  recovery-code digests. Returns `{:ok, %MfaFacts{}}`, or `{:error,
  :unauthorized}` for a non-user subject.
  """
  def mfa_facts(%Subject{actor: %Users.User{} = user}) do
    {:ok,
     %MfaFacts{
       enabled?: mfa_enabled?(user),
       recovery_codes_remaining: recovery_codes_remaining(user)
     }}
  end

  def mfa_facts(%Subject{}), do: {:error, :unauthorized}

  defp mfa_enabled?(%Users.User{mfa_enabled_at: %DateTime{}}), do: true
  defp mfa_enabled?(%Users.User{}), do: false

  # Unused digests — a consumed recovery code is removed from the row.
  defp recovery_codes_remaining(%Users.User{mfa_recovery_codes: codes}) when is_list(codes),
    do: length(codes)

  defp recovery_codes_remaining(%Users.User{}), do: 0

  @doc """
  Generates a fresh TOTP secret for the user. Caller is responsible
  for displaying the QR code; nothing is persisted until
  `enable_mfa/3` confirms the user has the secret.
  """
  def generate_mfa_secret, do: Crypto.totp_secret()

  # 10 recovery codes is the de facto standard (matches GitHub, Google
  # Workspace, etc). Returned in plaintext exactly once at enable-time;
  # we only persist the digests. Each code's shape (length, encoding,
  # digest) is `Crypto.mfa_recovery_code/0`'s concern.
  @recovery_code_count 10

  @doc """
  Enable TOTP for the caller. Verifies the OTP against the secret
  before flipping the bit; returns the freshly-generated **recovery
  codes** (plaintext, 10 single-use base32 strings) along with the
  user — show these once and never again. The plaintext leaves this
  function and the DB never sees it.

  Self-service — the user is the subject's own actor; the write happens
  on the locked re-read of their row (`Users.update_user_mfa/5`), so a
  stale socket snapshot can't clobber a concurrent credential change.
  """
  def enable_mfa(secret, otp, %Subject{actor: %Users.User{} = user} = subject)
      when is_binary(secret) and is_binary(otp) do
    if Crypto.valid_totp?(secret, otp) do
      {plain_codes, digests} = generate_recovery_codes()

      user.id
      |> Users.update_user_mfa(secret, DateTime.utc_now(), digests,
        audit: &Audit.user_changesets(&1, "user.mfa_enabled", context: subject.context)
      )
      |> case do
        {:ok, updated} -> {:ok, updated, plain_codes}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_otp}
    end
  end

  @doc """
  Disable TOTP for the caller after verifying a current TOTP or recovery code.
  The user is re-fetched before the factor check, and both verification paths
  validate against the current row under a lock. Returns {:ok, user} on
  success, {:error, :invalid_code | :replay} when the factor is rejected,
  {:error, :rate_limited} once the shared per-user MFA attempt window is
  exhausted, or the underlying update error.
  """
  def disable_mfa(code, %Subject{actor: %Users.User{id: id}} = subject)
      when is_binary(code) do
    code = String.trim(code)

    with {:ok, user} <- Users.fetch_user_by_id(id),
         {:ok, _verified} <- verify_disable_mfa_factor(user, code, subject.context) do
      Users.update_user_mfa(id, nil, nil, [],
        audit: &Audit.user_changesets(&1, "user.mfa_disabled", context: subject.context)
      )
    else
      {:error, :invalid} -> {:error, :invalid_code}
      {:error, :not_found} -> {:error, :invalid_code}
      {:error, reason} -> {:error, reason}
    end
  end

  def disable_mfa(_, %Subject{}), do: {:error, :invalid_code}

  defp verify_disable_mfa_factor(user, code, context) do
    if Regex.match?(~r/\A\d{6}\z/, code) do
      verify_mfa(user, code, context)
    else
      consume_mfa_recovery_code(user, code, context)
    end
  end

  @doc """
  Regenerate the recovery code set (e.g. user lost their printed copy).
  Invalidates the prior codes; returns the new plaintext set once.
  Requires MFA to already be enabled — refused on the locked row, not
  the caller's snapshot. Self-service — the user is the subject's own
  actor.
  """
  def regenerate_mfa_recovery_codes(%Subject{actor: %Users.User{} = user} = subject) do
    {plain_codes, digests} = generate_recovery_codes()

    user.id
    |> Users.put_user_mfa_recovery_codes(digests,
      audit:
        &Audit.user_changesets(&1, "user.mfa_recovery_codes_regenerated",
          context: subject.context
        )
    )
    |> case do
      {:ok, updated} -> {:ok, updated, plain_codes}
      {:error, reason} -> {:error, reason}
    end
  end

  defp generate_recovery_codes do
    1..@recovery_code_count
    |> Enum.map(fn _ -> Crypto.mfa_recovery_code() end)
    |> Enum.unzip()
  end

  # The second-factor brute-force policy: five attempts per user per five-minute
  # window, shared by every MFA challenge and step-up (sign-in, disable, email
  # change) and by both factors, so switching surface or factor doesn't stretch
  # the guessing budget.
  @mfa_challenge_attempt_limit 5
  @mfa_challenge_attempt_window_ms 5 * 60_000

  @doc """
  Verifies the sign-in second factor — `{:totp, otp}` or `{:recovery_code,
  code}` — behind the shared per-user fixed-window attempt cap, so no challenge
  caller can be used as an unbounded guessing oracle. The cap is keyed by user id
  (server-side), so a page reload or a fresh socket can't reset it, and every
  attempt counts toward the same window regardless of factor or surface.

  Pre-Subject — this is the sign-in second factor, so it takes the
  partially-authenticated `%Users.User{}` (no tenant resolved yet). Returns
  `{:ok, proof}` — an opaque term bound to the enrollment that was just
  verified, which `complete_magic_link_mfa_sign_in/3` re-checks against the
  locked row before minting anything — `{:error, :rate_limited}` once the window
  is exhausted, `{:error, :replay}` on a reused TOTP, or `{:error, :invalid}`
  otherwise; misses are audited as `user.mfa_failed`.
  """
  def verify_mfa_challenge(user, factor, context \\ %RequestContext{})

  def verify_mfa_challenge(%Users.User{} = user, {:totp, otp}, context) when is_binary(otp) do
    with {:ok, verified} <- verify_mfa(user, otp, context) do
      {:ok, mfa_proof(verified)}
    end
  end

  def verify_mfa_challenge(%Users.User{} = user, {:recovery_code, code}, context)
      when is_binary(code) do
    with {:ok, verified} <- consume_mfa_recovery_code(user, code, context) do
      {:ok, mfa_proof(verified)}
    end
  end

  def verify_mfa_challenge(_, _, _), do: {:error, :invalid}

  @doc """
  Internal — the user a verified MFA proof was minted for, so the sign-in
  boundary can bind completion to the browser that passed factor one without
  learning the proof's shape. Only the complete proof shape names anyone, so a
  bare `%{user_id: id}` a caller assembled itself is `nil` here and never reaches
  completion; `nil` likewise for anything else that isn't a proof.
  """
  def mfa_proof_user_id(proof) when is_binary(proof) do
    case verify_mfa_proof(proof) do
      {:ok, {:mfa_sign_in, user_id, %DateTime{}, %DateTime{}}} when is_binary(user_id) ->
        user_id

      _ ->
        nil
    end
  end

  def mfa_proof_user_id(_proof), do: nil

  # The domain signs the person, enrollment, and post-verification row version.
  # A caller can read those fields but cannot turn them into a proof without the
  # portal signing secret. Completion verifies the MAC before rebuilding and
  # comparing the payload from the locked row.
  defp mfa_proof(%Users.User{} = user) do
    Phoenix.Token.sign(
      mfa_proof_secret(),
      @mfa_sign_in_proof_salt,
      mfa_proof_payload(user)
    )
  end

  defp mfa_proof_payload(%Users.User{} = user),
    do: {:mfa_sign_in, user.id, user.mfa_enabled_at, user.updated_at}

  defp verify_mfa_proof(proof) when is_binary(proof) do
    Phoenix.Token.verify(mfa_proof_secret(), @mfa_sign_in_proof_salt, proof,
      max_age: @mfa_sign_in_proof_max_age_seconds
    )
  end

  defp verify_mfa_proof(_proof), do: {:error, :invalid}

  # Runtime derives this from the portal secret key base. Salt separation keeps
  # MFA proofs independent from the emailed-link signatures sharing the key.
  defp mfa_proof_secret, do: Application.fetch_env!(:emisar, :email_link_secret)

  defp throttle_mfa_challenge(%Users.User{id: user_id}) do
    Throttle.check(
      :mfa_challenge,
      user_id,
      @mfa_challenge_attempt_limit,
      @mfa_challenge_attempt_window_ms
    )
  end

  # Verifies a TOTP code with replay protection. A bare `Crypto.valid_totp?/2`
  # accepts the same code repeatedly within its 30-second window, so the
  # consume step stamps `mfa_last_used_at` on the **locked** row and rejects a
  # second claim of the same bucket — two concurrent submissions of one code
  # can't both pass. Every caller — sign-in (`verify_mfa_challenge/3`) and the
  # post-auth step-ups (`disable_mfa/2`, `confirm_email_change/3`) — reaches the
  # verifier through here, so the attempt cap is spent exactly once per request
  # and no surface is an unbounded oracle; a capped request never verifies, so it
  # neither stamps the row nor audits a miss it didn't make.
  defp verify_mfa(%Users.User{} = user, otp, context) when is_binary(otp) do
    with :ok <- throttle_mfa_challenge(user) do
      # The OTP is NOT validated against this (possibly stale) struct's secret —
      # `verify_and_consume_mfa` re-reads the row under a lock and validates +
      # consumes there, so a secret rotated/disabled mid-verify can't slip an old
      # code through. We only AUDIT here from the caller's user.
      case Users.verify_and_consume_mfa(user.id, otp, DateTime.utc_now()) do
        {:ok, %Users.User{} = verified} ->
          {:ok, verified}

        {:error, :replay} ->
          Audit.log_for_user(user, "user.mfa_failed",
            context: context,
            payload: %{reason: "replay"}
          )

          {:error, :replay}

        # Wrong code, MFA disabled, or the row vanished — all "this credential
        # can't complete sign-in" → a single invalid result, audited.
        {:error, _reason} ->
          Audit.log_for_user(user, "user.mfa_failed",
            context: context,
            payload: %{reason: "invalid_otp"}
          )

          {:error, :invalid}
      end
    end
  end

  # One-shot consume of a recovery code: removes it from the user's stored set
  # under the row lock, so concurrent submissions of the same code serialize
  # and only one wins. Carries the same shared attempt cap as `verify_mfa/3`
  # above, so a capped request keeps its code unspent.
  defp consume_mfa_recovery_code(%Users.User{} = user, raw, context) when is_binary(raw) do
    with :ok <- throttle_mfa_challenge(user) do
      digest = Crypto.hash(String.downcase(String.trim(raw)))

      case Users.consume_user_mfa_recovery_code(user.id, digest,
             audit: fn updated ->
               Audit.user_changesets(updated, "user.mfa_recovery_code_used", %{
                 context: context,
                 payload: %{remaining: length(updated.mfa_recovery_codes)}
               })
             end
           ) do
        {:ok, %Users.User{} = consumed} ->
          {:ok, consumed}

        {:error, :invalid} ->
          # No DB mutation on a wrong code — just an audit row standalone.
          Audit.log_for_user(user, "user.mfa_failed",
            context: context,
            payload: %{reason: "invalid_recovery_code"}
          )

          {:error, :invalid}

        {:error, _} ->
          {:error, :invalid}
      end
    end
  end
end
