defmodule Emisar.Auth do
  @moduledoc """
  Authentication: sign in/up flows, session tokens, magic links,
  password resets, email confirmation, MFA scaffold.

  All token types share `user_tokens` storage; `context` disambiguates
  semantics + validity window.
  """
  use Supervisor
  alias Ecto.Multi
  alias Emisar.{Accounts, Audit, Mailers}
  alias Emisar.Auth.MfaFacts
  alias Emisar.Auth.Role
  alias Emisar.Auth.SecurityAttemptWindow
  alias Emisar.Auth.SessionFacts
  alias Emisar.Auth.Subject
  alias Emisar.Auth.UserToken
  alias Emisar.Crypto
  alias Emisar.Repo
  alias Emisar.RequestContext
  alias Emisar.SSO
  alias Emisar.Users
  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__.Supervisor)
  end

  @impl Supervisor
  def init(_opts) do
    Supervisor.init([job_module("TokenRetention")], strategy: :one_for_one)
  end

  # Resolved at runtime, like every sibling context's job supervision: naming
  # the module directly puts a compile edge from Auth — which most of the schema
  # reaches — into the Jobs infrastructure, and `mix xref` fails the gate on the
  # cycle it closes.
  defp job_module(name), do: Module.safe_concat([__MODULE__, "Jobs", name])

  # -- Role vocabulary --------------------------------------------------

  @doc "All assignable membership roles, most-privileged first."
  def roles, do: Role.all()

  @doc "Display label for a membership role (atom or string)."
  def role_label(role), do: Role.label(role)

  @doc "One-line description of what a membership role can do — `nil` when unknown."
  def role_description(role), do: Role.description(role)

  @doc """
  Whether a membership role reaches runners at all — a role FACT beside its
  label and description, not an authorization decision. False for the finance
  seat, whose access is structurally nothing, so a surface can state the
  cleared value instead of offering a control that cannot change it.
  """
  def role_carries_runner_access?(role), do: Role.carries_runner_access?(role)

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
  active account and current identity-provider row locks while recording the
  sign-in and inserting the user-global session credential, so account/provider
  policy cannot change between the trust decision and the write. `opts` must
  carry the callback's same-user, same-account `:user_identity_id` and exact
  `:provider_identifier`; the locked provider is the sole authority for the
  token's IdP MFA stamp. Returns `{:ok, token, mfa?}`
  (the raw cookie value plus the committed MFA outcome) or an error tuple.
  """
  def complete_sso_account_sign_in(
        %Users.User{} = user,
        account_id,
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
    |> SSO.put_sign_in_authority(user, account_id, opts)
    |> Multi.merge(fn %{sso_user: locked_user} ->
      Users.put_sign_in(Multi.new(), locked_user, "sso", context)
    end)
    |> Multi.insert(:token, fn %{sign_in: signed_in_user, sso_provider: provider} ->
      mfa_verified_at = if provider.satisfies_mfa, do: DateTime.utc_now()

      UserToken.Changeset.session(signed_in_user, digest, metadata, :sso, mfa_verified_at, opts)
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{sso_provider: provider}} -> {:ok, token, provider.satisfies_mfa}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Internal — `EmisarWeb.UserAuth` resolves a request's session cookie to its
  user; the session token IS the credential, so there's no Subject yet.
  Returns `{:ok, user, token}` — the `%UserToken{}` rides alongside so the
  boundary reads its provenance (`auth_method` / `mfa_verified_at` /
  `user_identity_id`) off it and stamps the `%Subject{}`. The user is preloaded
  scoped to live users, so a soft-deleted user's token resolves to
  `{:error, :not_found}` — as do expired / unknown / non-binary tokens.
  """
  def fetch_user_and_token_by_session_token(token) when is_binary(token) do
    UserToken.Query.by_token_digest(Crypto.hash(token))
    |> UserToken.Query.by_context("session")
    |> UserToken.Query.not_expired("session")
    |> UserToken.Query.with_preloaded_user()
    |> Repo.one()
    |> case do
      %UserToken{user: %Users.User{} = user} = token -> {:ok, user, token}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Internal — does this session still count as second-factor verified? Judges the
  exact `{user, token}` pair `fetch_user_and_token_by_session_token/1` returns,
  and it is what the boundary calls to BUILD a `%Subject{}`, so there is no
  Subject to take.

  Local proof is carried separately from the authentication-time assurance: an
  SSO session may prove Emisar TOTP after the IdP authenticated it. The local
  stamp is bound to the user's CURRENT enrollment; the SSO stamp remains the
  IdP's independent claim.
  """
  def session_mfa_verified?(%Users.User{} = user, %UserToken{} = session) do
    not is_nil(session_mfa_enrollment_verified_at(user, session)) or
      sso_mfa_verified_at_authentication?(session)
  end

  def session_mfa_verified?(_user, _auth), do: false

  @doc """
  Internal — the exact local enrollment epoch this session proved, or nil. The
  boundary carries this value onto the Subject so a later locked actor re-read
  can compare epochs instead of trusting a request-time boolean.
  """
  def session_mfa_enrollment_verified_at(
        %Users.User{mfa_enabled_at: %DateTime{} = enabled_at},
        %UserToken{mfa_enrollment_verified_at: %DateTime{} = verified_enrollment}
      )
      when enabled_at == verified_enrollment,
      do: enabled_at

  def session_mfa_enrollment_verified_at(_user, _auth), do: nil

  defp sso_mfa_verified_at_authentication?(%UserToken{
         auth_method: :sso,
         mfa_verified_at: %DateTime{}
       }),
       do: true

  defp sso_mfa_verified_at_authentication?(_session), do: false

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

    Repo.delete_all(identity_session_tokens_query(user.id, identity_ids))
    disconnect_live_sessions(topics)
    :ok
  end

  @doc """
  Internal — delete the exact identity-bound sessions inside a caller's
  transaction and return their socket topics for that caller's after-commit
  effect. The session rows are the only source for those topics, so they must be
  selected through the same DELETE that removes them.
  """
  def delete_identity_session_tokens(%Users.User{} = user, identity_ids, repo)
      when is_list(identity_ids) do
    delete_identity_session_tokens(user.id, identity_ids, repo)
  end

  def delete_identity_session_tokens(user_id, identity_ids, repo)
      when is_binary(user_id) and is_list(identity_ids) do
    queryable =
      user_id
      |> identity_session_tokens_query(identity_ids)
      |> UserToken.Query.select_token_digests()

    {count, digests} = repo.delete_all(queryable)

    {:ok, %{count: count, socket_topics: Enum.map(digests, &live_socket_topic/1)}}
  end

  # Both transactional deletion and SCIM revocation use this exact session set.
  defp identity_session_tokens_query(user_id, identity_ids) do
    UserToken.Query.by_user_id(user_id)
    |> UserToken.Query.by_context("session")
    |> UserToken.Query.by_user_identity_ids(identity_ids)
  end

  @doc """
  Internal — capture a user's live-socket topics so a caller that DELETES those
  session rows inside a transaction can still disconnect the sockets afterwards.

  A topic is derived from its `user_tokens` row, so reading it after the delete
  yields nothing: `broadcast_disconnect_for_user/2` called from an `after_commit`
  that deleted the rows disconnects no one. Capture inside the transaction, then
  hand the result to `disconnect_live_socket_topics/1` after it commits.
  """
  def capture_live_socket_topics(%Users.User{} = user), do: live_socket_topics_for_user(user)

  @doc """
  Internal — broadcast a disconnect to topics captured by
  `capture_live_socket_topics/1`. Best-effort and idempotent.
  """
  def disconnect_live_socket_topics(topics) when is_list(topics),
    do: disconnect_live_sessions(topics)

  @doc """
  "Sign out everywhere except this device" — kills every session except
  the one whose stored token digest is `keep_digest` (the caller's current
  session) AND broadcasts a disconnect to each of those sessions' LiveView
  sockets. Returns the count of sessions terminated.

  Self-service only: the user signing out is the subject's own actor, so
  it's read from the `%Subject{}` rather than passed separately — there's
  no way to revoke anyone else's sessions through this path.
  """
  def revoke_and_disconnect_other_sessions!(
        keep_digest,
        %Subject{actor: %Users.User{} = user} = subject
      )
      when is_binary(keep_digest) do
    topics = live_socket_topics_for_user(user, except: keep_digest)
    count = revoke_other_sessions!(user, keep_digest, subject.context)
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
  (configured with its owning application via
  `:emisar, :session_disconnect_handler`) because
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
    case Emisar.Config.get_env(:emisar, :session_disconnect_handler) do
      {application, handler} when is_atom(application) and is_atom(handler) ->
        if application_started?(application), do: handler.disconnect_live_sessions(topics)

      _missing_or_invalid ->
        :ok
    end

    :ok
  end

  defp application_started?(application) do
    Enum.any?(Application.started_applications(), fn {started, _description, _version} ->
      started == application
    end)
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

  `presented_digest` is the digest of the caller's own session token: each
  stored digest is compared against it in constant time, so the row making
  this request comes back `current?: true` and no caller has to hash a token
  here. A `nil` (or otherwise non-binary) digest simply marks every row
  `current?: false`.

  Rows project into `%SessionFacts{}` — no token, no digest, no raw metadata —
  so the device list cannot leak credential material. Returns `{:ok,
  [%SessionFacts{}], %Paginator.Metadata{}}`, or `{:error, :unauthorized}` for
  a non-user subject.
  """
  def list_sessions_for_user(presented_digest, subject, opts \\ [])

  def list_sessions_for_user(presented_digest, %Subject{actor: %Users.User{} = user}, opts) do
    presented_digest = presented_session_digest(presented_digest)

    sessions_query =
      UserToken.Query.by_user_id(user.id)
      |> UserToken.Query.by_context("session")
      |> UserToken.Query.not_expired("session")

    case Repo.list(sessions_query, UserToken.Query, opts) do
      {:ok, tokens, metadata} ->
        {:ok, Enum.map(tokens, &session_facts(&1, presented_digest)), metadata}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def list_sessions_for_user(_presented_digest, %Subject{}, _opts), do: {:error, :unauthorized}

  defp presented_session_digest(digest) when is_binary(digest), do: digest
  defp presented_session_digest(_digest), do: nil

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
  sign-out). Self-service — the user comes from the subject's own actor, and
  the query is scoped to them so a malicious id can't kill another user's
  session. The deleted row returns its digest so only that session's LiveView
  sockets disconnect after the deletion and audit commit. Returns `:ok |
  {:error, term()}`; stable scoped denials are `:not_found` and
  `:unauthorized`, while an audit rejection returns its changeset.
  """
  def revoke_session(token_id, %Subject{actor: %Users.User{} = user} = subject) do
    if Repo.valid_uuid?(token_id) do
      session_query =
        UserToken.Query.by_id(token_id)
        |> UserToken.Query.by_user_id(user.id)
        |> UserToken.Query.by_context("session")
        |> UserToken.Query.select_token_digests()

      Multi.new()
      |> Multi.delete_all(:sessions, session_query)
      |> Multi.run(:revoked_session_topic, fn
        _repo, %{sessions: {1, [digest]}} ->
          {:ok, live_socket_topic(digest)}

        _repo, _changes ->
          {:error, :not_found}
      end)
      |> Audit.Multi.log_for_user(:audit, user, "user.session_revoked",
        extra: [context: subject.context],
        payload_fn: fn _ -> %{session_id: token_id} end
      )
      |> Repo.commit_multi(after_commit: &disconnect_revoked_session/1)
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  def revoke_session(_token_id, %Subject{}), do: {:error, :unauthorized}

  defp disconnect_revoked_session(%{revoked_session_topic: topic}),
    do: disconnect_live_sessions([topic])

  @doc """
  Internal — the token-deletion half of
  `revoke_and_disconnect_other_sessions!/2` (the Subject-fronted public
  surface): revoke every session except the one whose stored token digest
  is `keep_digest`.
  """
  def revoke_other_sessions!(%Users.User{} = user, keep_digest, context \\ %RequestContext{})
      when is_binary(keep_digest) do
    sessions_query =
      UserToken.Query.by_user_id(user.id)
      |> UserToken.Query.by_context("session")
      |> UserToken.Query.except_token_digest(keep_digest)

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

  # Online-guess budget for the alphanumeric magic-link secret. The nonce carries
  # the real entropy; this caps brute-force by anyone who somehow has it.
  @magic_link_attempts 5
  @magic_link_contexts ["magic_link", "magic_link_verified"]

  @doc """
  Internal — pre-auth: the whole magic-link request. Issues a split-code token
  and emails the code + link; the raw secret never leaves Auth, so no caller can
  relay a sign-in credential it didn't earn. The link IS the factor being minted,
  so there's no Subject yet.

  Options: `:account_ref` — the branded `/app/:account_id_or_slug` target the
  request came from, or `nil` for an unbranded sign-in; a disabled, deleted,
  unknown, or malformed ref is `{:error, :not_found}` and issues + sends nothing.
  `:return_to` — the already-validated local path carried into the emailed link.
  `:owner_registration` — the validated workspace + display-name intent
  recovered from the encrypted signup handoff, or `nil`; it stays on the
  server-side factor until the final session transaction applies the proved
  profile and creates the workspace atomically.
  `:prior_magic_link_token_id` — the exact browser-bound factor being replaced
  by a resend; its still-live server-side registration intent is inherited.

  Returns `{:ok, %{token_id: id, nonce: nonce, delivery: delivery}}` — the caller
  keeps `nonce` browser-side (a short-lived cookie) — where `delivery` is
  `{:ok, :sent}`, `{:ok, :suppressed}` (the address bounced or was marked spam,
  so nothing was sent), or `{:error, reason}`.
  """
  def request_magic_link(%Users.User{} = user, %RequestContext{} = context, opts \\ []) do
    with {:ok, account} <- ensure_magic_link_account(Keyword.get(opts, :account_ref)) do
      issue_and_deliver_magic_link(
        user,
        context,
        account,
        Keyword.get(opts, :return_to),
        Keyword.get(opts, :owner_registration),
        Keyword.get(opts, :prior_magic_link_token_id)
      )
    end
  end

  @doc """
  Internal — pre-auth web boundary: generates browser state with the same
  UUIDv7 id and nonce shape as a real
  magic-link request, but no persisted factor. The pre-auth web boundary uses it
  for unavailable/unknown neutral responses; completion necessarily fails
  because no token row owns the id.
  """
  def magic_link_decoy do
    {nonce, _secret, _digest} = Crypto.magic_link_token()
    %{token_id: Repo.generate_id(), nonce: nonce}
  end

  defp ensure_magic_link_account(nil), do: {:ok, nil}

  defp ensure_magic_link_account(account_ref) when is_binary(account_ref) do
    Accounts.fetch_account_by_id_or_slug(account_ref)
  end

  defp ensure_magic_link_account(_account_ref), do: {:error, :not_found}

  # The token + its audit row commit before the send, so the email is a
  # post-commit side effect the caller reports on rather than a step that can
  # undo an issued factor — a mailer outage must not leave the audit log
  # claiming a link that no longer exists.
  defp issue_and_deliver_magic_link(
         %Users.User{} = user,
         context,
         account,
         return_to,
         owner_registration,
         prior_token_id
       ) do
    with {:ok, locked_user, token_id, nonce, secret, registration} <-
           issue_magic_link(
             user.id,
             user.email,
             context,
             owner_registration,
             prior_token_id
           ) do
      delivery =
        case Mailers.UserNotifier.deliver_magic_link(
               locked_user,
               token_id,
               secret,
               context,
               return_to,
               account || registration
             ) do
          {:ok, %{suppressed: true}} -> {:ok, :suppressed}
          {:ok, _sent} -> {:ok, :sent}
          {:error, reason} -> {:error, reason}
        end

      {:ok, %{token_id: token_id, nonce: nonce, delivery: delivery}}
    end
  end

  # Mints the split-code token: the caller keeps `nonce` browser-side, the
  # `secret` (a short alphanumeric code) is emailed alongside a link carrying
  # `token_id` + `secret`. Deletes any prior outstanding magic-link token for the
  # user (single outstanding). Private — the raw secret stays inside Auth.
  defp issue_magic_link(user_id, expected_email, context, owner_registration, prior_token_id) do
    {nonce, secret, digest} = Crypto.magic_link_token()

    result =
      Multi.new()
      |> Multi.run(:user, fn repo, _changes ->
        with {:ok, user} <- Users.fetch_and_lock_user_by_id(user_id, repo),
             true <- user.email == expected_email do
          {:ok, user}
        else
          _ -> {:error, :not_found}
        end
      end)
      |> Multi.run(:requested_owner_registration, fn repo, %{user: user} ->
        requested_owner_registration(repo, user, owner_registration, prior_token_id)
      end)
      |> Accounts.put_owner_registration_intent(fn %{requested_owner_registration: registration} ->
        registration
      end)
      |> Multi.delete_all(:prior, fn %{user: user} ->
        UserToken.Query.by_user_id(user.id)
        |> UserToken.Query.by_contexts(@magic_link_contexts)
      end)
      |> Multi.insert(:token, fn %{user: user, owner_registration: registration} ->
        UserToken.Changeset.magic_link(
          user,
          digest,
          user.email,
          @magic_link_attempts,
          registration
        )
      end)
      |> Audit.Multi.log_for_user(:audit, nil, "user.magic_link_issued",
        user_fn: & &1.user,
        extra: [context: context]
      )
      |> Repo.commit_multi()

    case result do
      {:ok, %{user: user, token: token, owner_registration: registration}} ->
        {:ok, user, token.id, nonce, secret, registration}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp requested_owner_registration(_repo, %Users.User{}, %{} = registration, _token_id),
    do: {:ok, registration}

  defp requested_owner_registration(repo, %Users.User{} = user, nil, token_id)
       when is_binary(token_id) do
    factor =
      if Repo.valid_uuid?(token_id) do
        requested_magic_factor(repo, user, token_id)
      end

    {:ok, if(factor && factor.sent_to == user.email, do: magic_owner_registration(factor, user))}
  end

  defp requested_owner_registration(_repo, %Users.User{}, _registration, _token_id),
    do: {:ok, nil}

  # A resend carries the prior factor's registration intent forward, so freshness
  # is judged per CONTEXT like the verify path — a magic_link_verified factor
  # lives by verified_at + its own window, not the pending inserted_at window that
  # not_expired("magic_link") wrongly applied to every context (a signup that
  # verified at minute 14 then resent found no factor and silently lost its
  # workspace intent). Attempts don't gate the intent — the resend mints a fresh
  # code.
  defp requested_magic_factor(repo, %Users.User{} = user, token_id) do
    factor =
      UserToken.Query.by_user_id(user.id)
      |> UserToken.Query.by_contexts(@magic_link_contexts)
      |> UserToken.Query.by_id(token_id)
      |> repo.peek()

    if factor && magic_factor_within_window?(factor), do: factor
  end

  defp magic_factor_within_window?(%UserToken{
         context: "magic_link",
         inserted_at: %DateTime{} = inserted_at
       }),
       do: fresh_since?(inserted_at, UserToken.Query.magic_link_validity_in_minutes() * 60)

  defp magic_factor_within_window?(%UserToken{context: "magic_link_verified"} = factor),
    do: verified_magic_link_fresh?(factor)

  defp magic_factor_within_window?(%UserToken{}), do: false

  @doc "Validity window of a magic-link code, in minutes — for the sent-page countdown."
  def magic_link_validity_in_minutes, do: UserToken.Query.magic_link_validity_in_minutes()

  @doc """
  Verifies a split-code magic link by reconstructing `hash(nonce <> secret)` and
  matching it against the locked token row. BOTH halves are required, so an
  intercepted email link/code can't sign in without the originating browser's
  nonce. Success promotes that exact row into the short-lived factor the final
  session transaction consumes; retrying the correct halves is idempotent and
  never extends that factor's age. A wrong pending half spends one of the
  #{@magic_link_attempts} attempts, and a spent-out or expired token reads as
  `{:error, :invalid_or_expired}`.
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
    case peek_magic_link_user_id(token_id) do
      {:ok, user_id} ->
        Multi.new()
        |> Multi.run(:user, fn repo, _changes ->
          Users.fetch_and_lock_user_by_id(user_id, repo)
        end)
        |> Multi.run(:token, fn repo, %{user: user} ->
          loaded_token_query =
            UserToken.Query.by_id(token_id)
            |> UserToken.Query.by_user_id(user.id)
            |> UserToken.Query.by_contexts(@magic_link_contexts)
            |> UserToken.Query.lock_for_update()

          case repo.fetch(loaded_token_query, UserToken.Query) do
            {:ok, loaded_token} -> {:ok, loaded_token}
            {:error, :not_found} -> {:error, :invalid_or_expired}
          end
        end)
        |> Multi.run(:outcome, &verify_magic_link_outcome(&1, &2, secret, nonce))
        |> Multi.merge(fn
          %{outcome: :promote, token: token, user: user} ->
            Multi.new()
            |> Multi.update(
              :verified_factor,
              UserToken.Changeset.verified_magic_link(token, DateTime.utc_now())
            )
            |> Users.put_email_confirmation(user, "magic_link", context)

          %{outcome: :verified, token: token, user: user} ->
            Multi.new()
            |> Multi.put(:verified_factor, token)
            |> Multi.put(:confirmed_user, user)

          %{outcome: :invalid, user: user} ->
            Multi.new()
            |> Multi.put(:verified_factor, nil)
            |> Multi.put(:confirmed_user, user)
        end)
        |> Repo.commit_multi()
        |> case do
          {:ok, %{outcome: outcome, confirmed_user: user}}
          when outcome in [:promote, :verified] ->
            {:ok, user}

          {:ok, %{outcome: :invalid}} ->
            record_magic_link_failure(token_id, :invalid_or_expired, context)

          {:error, :not_found} ->
            record_magic_link_failure(token_id, :invalid_or_expired, context)

          {:error, reason} ->
            record_magic_link_failure(token_id, reason, context)
        end

      {:error, reason} ->
        record_magic_link_failure(token_id, reason, context)
    end
  end

  defp verify_magic_link_outcome(repo, %{user: user, token: token}, secret, nonce) do
    valid_digest? = Crypto.secure_compare(Crypto.magic_link_digest(nonce, secret), token.token)

    cond do
      token.sent_to != user.email ->
        {:ok, :invalid}

      token.context == "magic_link" and not pending_magic_link_fresh?(token) ->
        {:ok, :invalid}

      token.context == "magic_link_verified" and
          not verified_magic_link_reverification_allowed?(token) ->
        {:ok, :invalid}

      valid_digest? and token.context == "magic_link" ->
        {:ok, :promote}

      valid_digest? and token.context == "magic_link_verified" ->
        {:ok, :verified}

      token.context in @magic_link_contexts ->
        {:ok, _token} = repo.update(UserToken.Changeset.decrement_attempts(token))
        {:ok, :invalid}

      true ->
        {:ok, :invalid}
    end
  end

  defp pending_magic_link_fresh?(%UserToken{
         inserted_at: %DateTime{} = inserted_at,
         remaining_attempts: attempts
       }) do
    is_integer(attempts) and attempts > 0 and
      fresh_since?(inserted_at, UserToken.Query.magic_link_validity_in_minutes() * 60)
  end

  defp pending_magic_link_fresh?(%UserToken{}), do: false

  defp verified_magic_link_fresh?(%UserToken{metadata: %{"verified_at" => encoded}})
       when is_binary(encoded) do
    case DateTime.from_iso8601(encoded) do
      {:ok, verified_at, 0} ->
        fresh_since?(
          verified_at,
          UserToken.Query.magic_link_verified_validity_in_minutes() * 60
        )

      _ ->
        false
    end
  end

  defp verified_magic_link_fresh?(%UserToken{}), do: false

  # Retrying the public emailed halves retains the same online-guess budget after
  # promotion. Final session completion already holds the server-issued handoff,
  # so it checks only factor age and is not denied by somebody exhausting public
  # retries against the same row.
  defp verified_magic_link_reverification_allowed?(
         %UserToken{remaining_attempts: attempts} = token
       ),
       do: is_integer(attempts) and attempts > 0 and verified_magic_link_fresh?(token)

  defp fresh_since?(%DateTime{} = at, max_age_seconds) do
    DateTime.diff(DateTime.utc_now(), at, :second) in 0..max_age_seconds
  end

  # A magic-link sign-in failed. `user.sign_in_failed` is account-scoped, so it
  # only lands when the token still resolves to a real user (a live token with a
  # bad secret, or an expired/spent one that wasn't deleted). A consumed or
  # undecodable token has no user to attribute — logged server-side instead,
  # with the SAME `{:error, :invalid_or_expired}` return so the response can't
  # be turned into an email-enumeration oracle. Always returns the error.
  defp record_magic_link_failure(token_id, reason, context) when is_atom(reason) do
    case peek_magic_link_user(token_id) do
      {:ok, %Users.User{} = user} ->
        Audit.log_for_user(user, "user.sign_in_failed",
          payload: %{reason: reason, method: "magic_link"},
          context: context
        )

      :error ->
        Logger.warning("magic-link sign-in failed for an unresolvable token")
    end

    {:error, reason}
  end

  # A failed Multi step can forward a %Changeset{} or other non-atom reason, and
  # a changeset can't be JSON-encoded into the audit payload — a sign-in 500
  # plus an enumeration signal. Collapse every non-atom to the neutral reason a
  # spent or expired token already gives.
  defp record_magic_link_failure(token_id, _reason, context),
    do: record_magic_link_failure(token_id, :invalid_or_expired, context)

  # The unlocked lookup discovers only which user row to lock first. It grants
  # no authority: the transaction re-fetches and locks the exact factor after
  # locking that current user.
  defp peek_magic_link_user_id(token_id) do
    if Repo.valid_uuid?(token_id) do
      token =
        UserToken.Query.by_id(token_id)
        |> UserToken.Query.by_contexts(@magic_link_contexts)
        |> Repo.peek()

      case token do
        %UserToken{user_id: user_id} -> {:ok, user_id}
        _ -> {:error, :invalid_or_expired}
      end
    else
      {:error, :invalid_or_expired}
    end
  end

  defp peek_magic_link_user(token_id) do
    with {:ok, user_id} <- peek_magic_link_user_id(token_id),
         {:ok, user} <- Users.fetch_user_by_id(user_id) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  # -- Magic-link sign-in completion ------------------------------------

  @mfa_sign_in_proof_salt "mfa sign-in proof"
  @mfa_sign_in_proof_max_age_seconds 120
  @member_mfa_reset_proof_salt "member mfa reset proof"
  @member_mfa_reset_proof_max_age_seconds 120
  @security_attempt_scopes SecurityAttemptWindow.scopes()

  @doc """
  Internal — factor one is done (a magic link verified inbox possession) and the
  boundary asks the domain to finish the sign-in; the session token IS the
  credential being minted, so there's no Subject yet. `account_ref` is the
  already-validated branded `/app/:account_id_or_slug` target, or `nil`.

  The user is re-read HERE, never taken from the caller, so an enrollment that
  landed since the link was issued still forces the second factor; the same
  check runs again on the locked row inside the minting transaction. The
  session's provenance is fixed — `:magic_link` with no `mfa_verified_at` — so no
  caller can claim a factor it didn't verify.

  Returns `{:ok, user, token, target, registered?}` — `user` is the row the minting
  transaction locked and stamped, so the boundary installs the session for the
  state the domain actually signed in rather than its own earlier snapshot, and
  `target` is `{:member, account}`, `:not_member`, or `:no_target` (what the
  boundary routes on). `{:error, :mfa_required}` when the second factor is still
  owed, `{:error, {:account_disabled, account}}` when the branded account is on
  hold, or `{:error, :not_found}` when the user no longer resolves.
  """
  def complete_magic_link_sign_in(
        user_id,
        verified_token_id,
        account_ref,
        %RequestContext{} = context
      ) do
    with {:ok, user} <- Users.fetch_user_by_id(user_id) do
      target = resolve_post_auth_account(user, account_ref)

      complete_sign_in_for_target(
        target,
        &insert_magic_link_session(user, verified_token_id, &1, nil, context)
      )
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
  with `mfa_verified_at` stamped now.

  Same `{:ok, user, token, target, registered?}` success shape as
  `complete_magic_link_sign_in/4`; `{:error, :mfa_proof_stale}` when the proof no
  longer matches the row, `{:error, :invalid_or_expired}` when the exact verified
  inbox factor is stale or already consumed, `{:error, {:account_disabled,
  account}}`, or `{:error, :not_found}`.
  """
  def complete_magic_link_mfa_sign_in(
        proof,
        verified_token_id,
        account_ref,
        %RequestContext{} = context
      ) do
    with {:ok, user} <- Users.fetch_user_by_id(mfa_proof_user_id(proof)) do
      target = resolve_post_auth_account(user, account_ref)

      complete_sign_in_for_target(
        target,
        &insert_magic_link_session(user, verified_token_id, &1, proof, context)
      )
    end
  end

  # A disabled branded account never mints a session — its members are sent to
  # that account's own sign-in page, so the boundary needs the account back.
  defp complete_sign_in_for_target({:disabled, %Accounts.Account{} = account}, _mint),
    do: {:error, {:account_disabled, account}}

  defp complete_sign_in_for_target({:member, %Accounts.Account{} = account} = target, mint) do
    case mint.(account) do
      {:ok, user, token, registered?} -> {:ok, user, token, target, registered?}
      {:error, :account_disabled} -> {:error, {:account_disabled, account}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp complete_sign_in_for_target(target, mint) do
    case mint.(nil) do
      {:ok, user, token, registered?} -> {:ok, user, token, target, registered?}
      {:error, reason} -> {:error, reason}
    end
  end

  # The ONE magic-link session minter. `proof` is `nil` for a factor-one
  # completion and a verified MFA proof for factor two — it fixes BOTH the
  # re-check on the locked user row AND the `mfa_verified_at` provenance stamped
  # on the token, so the two can't disagree and no caller supplies either.
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
         verified_token_id,
         account,
         proof,
         %RequestContext{} = context
       )
       when is_binary(verified_token_id) do
    {token, digest} = Crypto.session_token()
    metadata = %{ip_address: context.ip_address, user_agent: context.user_agent}
    # The proof IS factor two, so its presence decides whether this session
    # records a second factor and its arrival time is when that factor was shown.
    mfa_verified_at = if proof, do: DateTime.utc_now()

    Multi.new()
    |> lock_sign_in_account(account)
    |> Multi.run(:user, fn repo, _changes ->
      Users.fetch_and_lock_user_by_id(user.id, repo)
    end)
    |> Multi.run(:verified_factor, fn repo, %{user: loaded_user} ->
      lock_verified_magic_link(verified_token_id, loaded_user, repo)
    end)
    |> Multi.run(:mfa_state, fn _repo, %{user: loaded_user} ->
      with :ok <- ensure_mfa_state_current(loaded_user, proof), do: {:ok, proof}
    end)
    |> Accounts.put_owner_registration_intent(fn %{
                                                   user: loaded_user,
                                                   verified_factor: factor
                                                 } ->
      magic_owner_registration(factor, loaded_user)
    end)
    |> Multi.merge(fn %{user: loaded_user, owner_registration: registration} ->
      Multi.new()
      |> Users.put_owner_registration_profile(loaded_user, registration)
      |> Accounts.put_owner_registration(registration)
    end)
    |> Multi.merge(fn %{registration_user: registration_user} ->
      Users.put_sign_in(Multi.new(), registration_user, "magic_link", context)
    end)
    |> Multi.insert(:token, fn %{sign_in: signed_in_user} ->
      UserToken.Changeset.session(signed_in_user, digest, metadata, :magic_link, mfa_verified_at)
    end)
    |> Multi.delete(:consumed_magic_factor, fn %{verified_factor: factor} -> factor end)
    |> Repo.commit_multi(after_commit: &Accounts.after_membership_activation_committed/1)
    |> case do
      {:ok, %{sign_in: signed_in_user, registration: registered?}} ->
        {:ok, signed_in_user, token, registered?}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp magic_owner_registration(
         %UserToken{
           metadata: %{
             "registration_account_name" => account_name,
             "registration_full_name" => full_name
           }
         },
         %Users.User{}
       )
       when is_binary(account_name) and (is_binary(full_name) or is_nil(full_name)),
       do: %{account_name: account_name, full_name: full_name}

  defp magic_owner_registration(%UserToken{}, %Users.User{}), do: nil

  defp lock_verified_magic_link(token_id, %Users.User{} = user, repo) do
    factor_query =
      UserToken.Query.by_id(token_id)
      |> UserToken.Query.by_user_id(user.id)
      |> UserToken.Query.by_context("magic_link_verified")
      |> UserToken.Query.lock_for_update()

    with {:ok, factor} <- repo.fetch(factor_query, UserToken.Query),
         true <- factor.sent_to == user.email and verified_magic_link_fresh?(factor) do
      {:ok, factor}
    else
      _ -> {:error, :invalid_or_expired}
    end
  end

  defp lock_signing_in_user(user_id, proof, repo) do
    with {:ok, loaded_user} <- Users.fetch_and_lock_user_by_id(user_id, repo),
         :ok <- ensure_mfa_state_current(loaded_user, proof) do
      {:ok, loaded_user}
    end
  end

  defp lock_sign_in_account(multi, nil), do: multi

  defp lock_sign_in_account(multi, %Accounts.Account{id: account_id}) do
    Multi.run(multi, :sign_in_account, fn repo, _changes ->
      case Accounts.fetch_and_lock_account(account_id, repo: repo) do
        {:ok, account} -> {:ok, account}
        {:error, :not_found} -> {:error, :account_disabled}
      end
    end)
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
  @address_token_contexts [
    "magic_link",
    "magic_link_verified",
    "confirm",
    "email_change",
    "oidc_identity_step_up",
    "mfa_enrollment_pending",
    "mfa_enrollment"
  ]
  @email_change_issue_limit 5
  @email_change_issue_window_ms 15 * 60_000
  @inbox_step_up_limit 5
  @inbox_step_up_window_ms 5 * 60_000
  @oidc_identity_step_up_attempts 5
  @oidc_identity_step_up_issue_limit 5
  @oidc_identity_step_up_issue_window_ms 15 * 60_000
  @oidc_identity_step_up_proof_salt "oidc identity step up proof"
  @oidc_identity_step_up_proof_max_age_seconds 5 * 60

  @doc """
  Mints + emails a 6-digit step-up code to the user's CURRENT address, binding
  it to `new_email`. A self-service email change must re-enter it first, so the
  identity-defining field (it controls every future magic link) gets a
  credential-grade gate a stolen session alone can't pass. Deletes any prior
  outstanding email-change code (single outstanding). Issuance has one durable
  five-per-15-minute budget across direct starts and resends. Reports the
  delivery outcome: `{:ok, :sent}`, `{:ok, :suppressed}` (the provider won't
  deliver to the current address), or `{:error, :not_found | :rate_limited}`.
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
    with :ok <-
           throttle_security_attempt(
             user,
             :email_change_issue,
             @email_change_issue_limit,
             @email_change_issue_window_ms,
             subject.context
           ) do
      {code, digest} = Crypto.credential_step_up_code()

      result =
        Multi.new()
        |> Multi.run(:user, fn repo, _changes ->
          Users.fetch_and_lock_user_by_id(user.id, repo)
        end)
        |> Multi.delete_all(:prior, fn %{user: loaded_user} ->
          UserToken.Query.by_user_id(loaded_user.id)
          |> UserToken.Query.by_context("email_change")
        end)
        |> Multi.insert(:token, fn %{user: loaded_user} ->
          UserToken.Changeset.email_change(
            loaded_user,
            digest,
            new_email,
            @email_change_attempts
          )
        end)
        |> Audit.Multi.log_for_user(:audit, nil, "user.email_change_requested",
          user_fn: & &1.user,
          extra: [context: subject.context]
        )
        |> Repo.commit_multi()

      case result do
        {:ok, %{user: loaded_user}} ->
          case Mailers.UserNotifier.deliver_email_change_code(
                 loaded_user,
                 code,
                 new_email,
                 subject.context,
                 subject.account
               ) do
            {:ok, %{suppressed: true}} -> {:ok, :suppressed}
            {:ok, _sent} -> {:ok, :sent}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Begin a self-service email change: the DOMAIN decides the step-up factor from
  the user's CURRENT row — an MFA user re-enters TOTP (`:totp`), otherwise a
  one-time code is emailed to the current address to prove inbox control
  (`:code`, issued here). Returns `{:ok, :totp | :code}` or
  `{:error, :not_found | :rate_limited | :delivery_suppressed}` —
  `:delivery_suppressed` when the current address can't receive the code, so
  the change can't proceed. The factor is the domain's call so a stale MFA
  snapshot in the caller can't downgrade the challenge, and
  `confirm_email_change/3` re-derives it the same way.
  """
  def begin_email_change(new_email, %Subject{actor: %Users.User{id: id}} = subject)
      when is_binary(new_email) do
    with {:ok, user} <- Users.fetch_user_by_id(id) do
      case email_change_factor(user) do
        :totp ->
          {:ok, :totp}

        :code ->
          case do_issue_email_change_code(new_email, user, subject) do
            {:ok, :sent} -> {:ok, :code}
            {:ok, :suppressed} -> {:error, :delivery_suppressed}
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  @doc """
  Confirm a self-service email change: re-derive the required factor from the
  user's CURRENT row, verify `code` against it (TOTP for an MFA user, the emailed
  one-time code otherwise), and only on success apply the new email. The user
  change, invalidation of every old address credential, new confirmation token,
  and audit commit together. `{:ok, user} | {:error, :invalid |
  :replay | :rate_limited | %Ecto.Changeset{}}` — the TOTP branch spends an
  attempt from the shared per-user MFA window, so it is `:rate_limited` once that
  window is exhausted. The emailed-code branch has both its single-use token
  budget and the durable per-user inbox budget described above.
  """
  def confirm_email_change(new_email, code, %Subject{actor: %Users.User{id: id}} = subject)
      when is_binary(new_email) and is_binary(code) do
    with {:ok, user} <- Users.fetch_user_by_id(id) do
      case email_change_factor(user) do
        :totp ->
          with :ok <- throttle_mfa_challenge(user, subject.context) do
            apply_email_change(id, new_email, {:mfa, code}, subject)
          end

        :code ->
          with :ok <-
                 throttle_security_attempt(
                   user,
                   :inbox_step_up,
                   @inbox_step_up_limit,
                   @inbox_step_up_window_ms,
                   subject.context
                 ) do
            apply_email_change(id, new_email, {:email_code, code}, subject)
          end
      end
    end
  end

  defp email_change_factor(%Users.User{mfa_enabled_at: %DateTime{}}), do: :totp
  defp email_change_factor(%Users.User{}), do: :code

  defp apply_email_change(user_id, requested_email, factor, %Subject{} = subject) do
    {raw_confirmation, confirmation_digest} = Crypto.email_token()

    result =
      Multi.new()
      |> Multi.run(:user, fn repo, _changes ->
        Users.fetch_and_lock_user_by_id(user_id, repo)
      end)
      |> Multi.run(:factor_outcome, fn repo, %{user: user} ->
        verify_email_change_factor(repo, user, requested_email, factor)
      end)
      |> Multi.merge(fn
        %{factor_outcome: {:ok, email, factor_user}} ->
          Multi.new()
          |> Users.put_email_change(factor_user, email, subject.context)
          |> Multi.delete_all(:invalidated_address_tokens, fn %{email_change: updated} ->
            UserToken.Query.by_user_id(updated.id)
            |> UserToken.Query.by_contexts(@address_token_contexts)
          end)
          |> Multi.insert(:confirmation_token, fn %{email_change: updated} ->
            UserToken.Changeset.hashed(updated, confirmation_digest, "confirm", updated.email)
          end)

        %{factor_outcome: {:error, _reason}} ->
          Multi.new()
      end)
      |> Repo.commit_multi()

    case result do
      {:ok, %{factor_outcome: {:ok, _email, _user}, email_change: updated}} ->
        _ =
          Mailers.UserNotifier.deliver_email_change_confirmation(
            updated,
            raw_confirmation,
            subject.account,
            subject.context
          )

        {:ok, updated}

      {:ok, %{factor_outcome: {:error, reason}, user: user}} ->
        record_email_change_factor_failure(factor, user, reason, subject.context)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_email_change_factor(_repo, %Users.User{} = user, requested_email, {:mfa, otp}) do
    case Users.verify_and_consume_mfa(user.id, otp, []) do
      {:ok, verified} -> {:ok, {:ok, requested_email, verified}}
      {:error, :replay} -> {:ok, {:error, :replay}}
      {:error, _reason} -> {:ok, {:error, :invalid}}
    end
  end

  defp verify_email_change_factor(repo, %Users.User{mfa_enabled_at: nil} = user, _email, {
         :email_code,
         code
       }) do
    token =
      UserToken.Query.by_user_id(user.id)
      |> UserToken.Query.by_context("email_change")
      |> UserToken.Query.not_expired("email_change")
      |> UserToken.Query.with_attempts_remaining()
      |> UserToken.Query.lock_for_update()
      |> repo.one()

    cond do
      is_nil(token) ->
        {:ok, {:error, :invalid}}

      Crypto.secure_compare(Crypto.hash(code), token.token) ->
        {:ok, {:ok, token.sent_to, user}}

      true ->
        {:ok, _token} = repo.update(UserToken.Changeset.decrement_attempts(token))
        {:ok, {:error, :invalid}}
    end
  end

  defp verify_email_change_factor(_repo, %Users.User{}, _email, _factor),
    do: {:ok, {:error, :invalid}}

  defp record_email_change_factor_failure({:mfa, _otp}, user, reason, context) do
    Audit.log_for_user(user, "user.mfa_failed",
      context: context,
      payload: %{reason: if(reason == :replay, do: "replay", else: "invalid_otp")}
    )

    {:error, reason}
  end

  # The emailed-code branch (a hijacked session grinding the 6-digit code) left no
  # trace where the TOTP branch above records one — audit each miss.
  defp record_email_change_factor_failure({:email_code, _code}, user, reason, context) do
    Audit.log_for_user(user, "user.email_change_code_failed",
      context: context,
      payload: %{reason: to_string(reason)}
    )

    {:error, reason}
  end

  defp record_email_change_factor_failure(_factor, _user, reason, _context),
    do: {:error, reason}

  # -- OIDC identity step-up ------------------------------------------

  @doc """
  Begin fresh local proof before linking, testing, or removing an OIDC identity.
  A user with local MFA supplies an authenticator or recovery code; otherwise a
  single-use code goes to the current inbox. The provider and purpose are bound
  into both the stored code and the short-lived proof returned by confirmation.
  Returns `{:ok, :mfa | :email}` or
  `{:error, :not_found | :rate_limited | :delivery_suppressed}` —
  `:delivery_suppressed` when the current address can't receive the code.
  """
  def begin_oidc_identity_step_up(
        provider_id,
        provider_name,
        purpose,
        %Subject{actor: %Users.User{id: user_id}} = subject
      )
      when is_binary(provider_id) and is_binary(provider_name) and
             purpose in [:link, :verify_provider, :unlink] do
    with {:ok, user} <- Users.fetch_user_by_id(user_id) do
      if mfa_enabled?(user) do
        {:ok, :mfa}
      else
        case issue_oidc_identity_step_up_code(
               user,
               provider_id,
               provider_name,
               purpose,
               subject
             ) do
          {:ok, :sent} -> {:ok, :email}
          {:ok, :suppressed} -> {:error, :delivery_suppressed}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  @doc """
  Issue a replacement current-inbox code for an in-progress OIDC identity step-up.
  Returns `{:ok, :sent}`, `{:ok, :suppressed}` (the current address can't receive
  it), or `{:error, :not_found | :rate_limited | :factor_changed}`.
  """
  def resend_oidc_identity_step_up_code(
        provider_id,
        provider_name,
        purpose,
        %Subject{actor: %Users.User{id: user_id}} = subject
      )
      when is_binary(provider_id) and is_binary(provider_name) and
             purpose in [:link, :verify_provider, :unlink] do
    case Users.fetch_user_by_id(user_id) do
      {:ok, %Users.User{mfa_enabled_at: nil} = user} ->
        issue_oidc_identity_step_up_code(user, provider_id, provider_name, purpose, subject)

      {:ok, %Users.User{}} ->
        {:error, :factor_changed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp issue_oidc_identity_step_up_code(user, provider_id, provider_name, purpose, subject) do
    with :ok <-
           throttle_security_attempt(
             user,
             :oidc_identity_step_up_issue,
             @oidc_identity_step_up_issue_limit,
             @oidc_identity_step_up_issue_window_ms,
             subject.context
           ) do
      {code, digest} = Crypto.credential_step_up_code()

      result =
        Multi.new()
        |> Multi.run(:user, fn repo, _changes ->
          with {:ok, locked_user} <- Users.fetch_and_lock_user_by_id(user.id, repo),
               nil <- locked_user.mfa_enabled_at do
            {:ok, locked_user}
          else
            %DateTime{} -> {:error, :factor_changed}
            {:error, reason} -> {:error, reason}
          end
        end)
        |> Multi.delete_all(:prior, fn %{user: locked_user} ->
          UserToken.Query.by_user_id(locked_user.id)
          |> UserToken.Query.by_context("oidc_identity_step_up")
        end)
        |> Multi.insert(:token, fn %{user: locked_user} ->
          UserToken.Changeset.oidc_identity_step_up(
            locked_user,
            digest,
            provider_id,
            purpose,
            @oidc_identity_step_up_attempts
          )
        end)
        |> Audit.Multi.log_for_user(:audit, nil, "user.oidc_identity_step_up_requested",
          user_fn: & &1.user,
          payload_fn: fn _changes ->
            %{provider_id: provider_id, purpose: Atom.to_string(purpose)}
          end,
          extra: [context: subject.context]
        )
        |> Repo.commit_multi()

      case result do
        {:ok, %{user: locked_user}} ->
          case Mailers.UserNotifier.deliver_oidc_identity_step_up_code(
                 locked_user,
                 code,
                 provider_name,
                 purpose,
                 subject.context,
                 subject.account
               ) do
            {:ok, %{suppressed: true}} -> {:ok, :suppressed}
            {:ok, _sent} -> {:ok, :sent}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Confirm fresh local proof and return an opaque OIDC-purpose proof."
  def confirm_oidc_identity_step_up(
        provider_id,
        purpose,
        code,
        %Subject{actor: %Users.User{id: user_id}} = subject
      )
      when is_binary(provider_id) and is_binary(code) and
             purpose in [:link, :verify_provider, :unlink] do
    code = String.trim(code)

    with {:ok, user} <- Users.fetch_user_by_id(user_id),
         {:ok, verified_user} <-
           verify_oidc_identity_step_up_factor(user, provider_id, purpose, code, subject) do
      {:ok, oidc_identity_step_up_proof(verified_user, provider_id, purpose)}
    end
  end

  defp verify_oidc_identity_step_up_factor(
         %Users.User{mfa_enabled_at: %DateTime{}} = user,
         _provider_id,
         _purpose,
         code,
         subject
       ),
       do: verify_current_mfa_factor(user, code, subject.context)

  defp verify_oidc_identity_step_up_factor(user, provider_id, purpose, code, subject) do
    with :ok <-
           throttle_security_attempt(
             user,
             :inbox_step_up,
             @inbox_step_up_limit,
             @inbox_step_up_window_ms,
             subject.context
           ) do
      case consume_oidc_identity_step_up_code(user.id, provider_id, purpose, code) do
        {:ok, verified_user} ->
          {:ok, verified_user}

        # A wrong or expired emailed code leaves an audit trail (the TOTP factor
        # path records its miss too) so grinding a hijacked session is visible.
        {:error, reason} ->
          Audit.log_for_user(user, "user.oidc_identity_step_up_failed",
            context: subject.context,
            payload: %{reason: to_string(reason), purpose: Atom.to_string(purpose)}
          )

          {:error, reason}
      end
    end
  end

  defp consume_oidc_identity_step_up_code(user_id, provider_id, purpose, code) do
    Multi.new()
    |> Multi.run(:user, fn repo, _changes -> Users.fetch_and_lock_user_by_id(user_id, repo) end)
    |> Multi.run(:outcome, fn repo, %{user: user} ->
      token =
        UserToken.Query.by_user_id(user.id)
        |> UserToken.Query.by_context("oidc_identity_step_up")
        |> UserToken.Query.not_expired("oidc_identity_step_up")
        |> UserToken.Query.with_attempts_remaining()
        |> UserToken.Query.lock_for_update()
        |> repo.one()

      verify_oidc_identity_step_up_code(repo, token, user, provider_id, purpose, code)
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{outcome: {:ok, user}}} -> {:ok, user}
      {:ok, %{outcome: {:error, reason}}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_oidc_identity_step_up_code(repo, token, user, provider_id, purpose, code) do
    expected_metadata = %{
      "provider_id" => provider_id,
      "purpose" => Atom.to_string(purpose),
      "user_updated_at" => DateTime.to_iso8601(user.updated_at)
    }

    cond do
      is_nil(token) or not is_nil(user.mfa_enabled_at) ->
        {:ok, {:error, :invalid}}

      token.sent_to != user.email or token.metadata != expected_metadata ->
        {:ok, {:error, :invalid}}

      Crypto.secure_compare(Crypto.hash(code), token.token) ->
        {:ok, _deleted} = repo.delete(token)
        {:ok, {:ok, user}}

      true ->
        {:ok, _updated} = repo.update(UserToken.Changeset.decrement_attempts(token))
        {:ok, {:error, :invalid}}
    end
  end

  @doc "Recheck an OIDC identity proof against a freshly loaded user row."
  def verify_oidc_identity_step_up_proof(proof, provider_id, purpose, %Users.User{} = user)
      when is_binary(proof) and is_binary(provider_id) and
             purpose in [:link, :verify_provider, :unlink] do
    case Phoenix.Token.verify(mfa_proof_secret(), @oidc_identity_step_up_proof_salt, proof,
           max_age: @oidc_identity_step_up_proof_max_age_seconds
         ) do
      {:ok, payload} ->
        if payload == oidc_identity_step_up_proof_payload(user, provider_id, purpose),
          do: :ok,
          else: {:error, :identity_step_up_stale}

      _other ->
        {:error, :identity_step_up_stale}
    end
  end

  def verify_oidc_identity_step_up_proof(_proof, _provider_id, _purpose, %Users.User{}),
    do: {:error, :identity_step_up_stale}

  @doc "Lock and verify the exact live session bound to an OIDC identity action."
  def ensure_oidc_identity_step_up_current(
        repo,
        proof,
        session_token_digest,
        provider_id,
        purpose,
        %Users.User{} = user
      )
      when is_binary(session_token_digest) do
    session_query =
      UserToken.Query.by_token_digest(session_token_digest)
      |> UserToken.Query.by_user_id(user.id)
      |> UserToken.Query.by_context("session")
      |> UserToken.Query.not_expired("session")
      |> UserToken.Query.lock_for_update()

    with :ok <- verify_oidc_identity_step_up_proof(proof, provider_id, purpose, user),
         {:ok, %UserToken{}} <- repo.fetch(session_query, UserToken.Query) do
      :ok
    else
      _other -> {:error, :identity_step_up_stale}
    end
  end

  defp oidc_identity_step_up_proof(user, provider_id, purpose) do
    Phoenix.Token.sign(
      mfa_proof_secret(),
      @oidc_identity_step_up_proof_salt,
      oidc_identity_step_up_proof_payload(user, provider_id, purpose)
    )
  end

  defp oidc_identity_step_up_proof_payload(user, provider_id, purpose) do
    {:oidc_identity_step_up, user.id, user.email, user.mfa_enabled_at, user.updated_at,
     provider_id, purpose}
  end

  # -- Email confirmation ----------------------------------------------

  @doc """
  Issues a fresh confirmation token and emails the confirm link. The one
  place "send a confirmation email" lives — sign-up, the Team-page resend,
  and the portal banner all call this so the token + delivery never drift.
  Best-effort: returns `:ok` regardless of the mailer result.
  """
  def deliver_confirmation_instructions(
        %Users.User{} = user,
        account \\ nil,
        context \\ %RequestContext{}
      ) do
    with {:ok, locked_user, token} <- issue_confirmation_token(user.id) do
      _ =
        Mailers.UserNotifier.deliver_account_confirmation(
          locked_user,
          token,
          account,
          context
        )
    end

    :ok
  end

  defp issue_confirmation_token(user_id) do
    {raw, digest} = Crypto.email_token()

    result =
      Multi.new()
      |> Multi.run(:user, fn repo, _changes ->
        Users.fetch_and_lock_user_by_id(user_id, repo)
      end)
      |> Multi.delete_all(:prior, fn %{user: user} ->
        UserToken.Query.by_user_id(user.id)
        |> UserToken.Query.by_context("confirm")
      end)
      |> Multi.insert(:token, fn %{user: user} ->
        UserToken.Changeset.hashed(user, digest, "confirm", user.email)
      end)
      |> Repo.commit_multi()

    case result do
      {:ok, %{user: user}} -> {:ok, user, raw}
      {:error, reason} -> {:error, reason}
    end
  end

  def confirm_user_by_token(raw, context \\ %RequestContext{}) when is_binary(raw) do
    case Crypto.email_token_digest(raw) do
      :error ->
        {:error, :invalid_or_expired}

      {:ok, digest} ->
        confirm_user_by_digest(digest, context)
    end
  end

  defp confirm_user_by_digest(digest, context) do
    pending =
      UserToken.Query.by_token_digest(digest)
      |> UserToken.Query.by_context("confirm")
      |> Repo.peek()

    case pending do
      %UserToken{user_id: user_id} ->
        Multi.new()
        |> Multi.run(:user, fn repo, _changes ->
          Users.fetch_and_lock_user_by_id(user_id, repo)
        end)
        |> Multi.run(:token, fn repo, %{user: user} ->
          token_query =
            UserToken.Query.by_token_digest(digest)
            |> UserToken.Query.by_user_id(user.id)
            |> UserToken.Query.by_context("confirm")
            |> UserToken.Query.not_expired("confirm")
            |> UserToken.Query.lock_for_update()

          with {:ok, token} <- repo.fetch(token_query, UserToken.Query),
               true <- token.sent_to == user.email do
            {:ok, token}
          else
            _ -> {:error, :invalid_or_expired}
          end
        end)
        |> Multi.merge(fn %{user: user} ->
          Users.put_email_confirmation(Multi.new(), user, "confirmation_link", context)
        end)
        |> Multi.delete(:deleted_token, fn %{token: token} -> token end)
        |> Repo.commit_multi()
        |> case do
          {:ok, %{confirmed_user: confirmed}} -> {:ok, confirmed}
          {:error, :not_found} -> {:error, :invalid_or_expired}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :invalid_or_expired}
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

  @mfa_enrollment_code_attempts 5
  @mfa_enrollment_issue_limit 5
  @mfa_enrollment_issue_window_ms 15 * 60_000
  @mfa_enrollment_pending_max_age_seconds 60
  @mfa_enrollment_proof_salt "mfa enrollment proof"
  @mfa_enrollment_proof_max_age_seconds 5 * 60

  @doc """
  Emails a current-inbox proof code before a user may enroll a new MFA factor.
  The dedicated token is single-use, expires after 15 minutes, and has five
  token-local guesses. Delivery also shares a durable five-per-15-minute budget
  across Portal nodes and reloads. Returns `{:ok, :sent}`, `{:ok, :suppressed}`
  when the address cannot receive Emisar mail, or `{:error, reason}` when the
  mail provider rejects the send.
  """
  def issue_mfa_enrollment_code(%Subject{actor: %Users.User{id: id}} = subject) do
    with {:ok, user} <- Users.fetch_user_by_id(id),
         :ok <- ensure_mfa_not_enabled(user),
         :ok <- ensure_mfa_enrollment_email(user),
         :ok <-
           throttle_security_attempt(
             user,
             :mfa_enrollment_issue,
             @mfa_enrollment_issue_limit,
             @mfa_enrollment_issue_window_ms,
             subject.context
           ) do
      {code, digest} = Crypto.credential_step_up_code()

      Multi.new()
      |> Multi.run(:user, fn repo, _changes ->
        with {:ok, locked_user} <- Users.fetch_and_lock_user_by_id(user.id, repo),
             :ok <- ensure_mfa_not_enabled(locked_user),
             :ok <- ensure_mfa_enrollment_email(locked_user) do
          {:ok, locked_user}
        end
      end)
      |> Multi.run(:token, fn repo, %{user: locked_user} ->
        pending_query =
          UserToken.Query.by_user_id(locked_user.id)
          |> UserToken.Query.by_context("mfa_enrollment_pending")
          |> UserToken.Query.lock_for_update()

        pending_tokens = repo.all(pending_query)

        if Enum.any?(pending_tokens, &recent_mfa_enrollment_pending?/1) do
          {:error, :issuance_in_progress}
        else
          # A process can die after recording a request but before finalizing its
          # delivery. Reclaim that non-verifiable pending row after the mailer's
          # maximum useful wait while the user lock excludes a competing issue.
          {_count, nil} =
            UserToken.Query.by_user_id(locked_user.id)
            |> UserToken.Query.by_context("mfa_enrollment_pending")
            |> repo.delete_all()

          UserToken.Changeset.pending_mfa_enrollment(
            locked_user,
            digest,
            @mfa_enrollment_code_attempts
          )
          |> repo.insert()
        end
      end)
      |> Audit.Multi.log_for_user(:audit, nil, "user.mfa_enrollment_requested",
        user_fn: & &1.user,
        extra: [context: subject.context]
      )
      |> Repo.commit_multi()
      |> case do
        {:ok, %{user: locked_user, token: token}} ->
          delivery =
            case Mailers.UserNotifier.deliver_mfa_enrollment_code(
                   locked_user,
                   code,
                   subject.context,
                   subject.account
                 ) do
              {:ok, %{suppressed: true}} -> {:ok, :suppressed}
              {:ok, _sent} -> {:ok, :sent}
              {:error, reason} -> {:error, reason}
            end

          finalize_mfa_enrollment_delivery(token, locked_user.id, delivery)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp recent_mfa_enrollment_pending?(%UserToken{inserted_at: inserted_at}) do
    DateTime.diff(DateTime.utc_now(), inserted_at, :second) <
      @mfa_enrollment_pending_max_age_seconds
  end

  defp finalize_mfa_enrollment_delivery(
         %UserToken{} = pending,
         user_id,
         {:ok, :sent} = delivery
       ) do
    Multi.new()
    |> Multi.run(:user, fn repo, _changes -> Users.fetch_and_lock_user_by_id(user_id, repo) end)
    |> Multi.run(:pending, fn repo, _changes ->
      loaded_query =
        UserToken.Query.by_id(pending.id)
        |> UserToken.Query.by_user_id(user_id)
        |> UserToken.Query.by_context("mfa_enrollment_pending")
        |> UserToken.Query.lock_for_update()

      case repo.fetch(loaded_query, UserToken.Query) do
        {:ok, loaded} -> {:ok, loaded}
        {:error, :not_found} -> {:error, :issuance_expired}
      end
    end)
    |> Multi.delete_all(:prior, fn _changes ->
      UserToken.Query.by_user_id(user_id)
      |> UserToken.Query.by_context("mfa_enrollment")
    end)
    |> Multi.update(:token, fn %{pending: loaded} ->
      UserToken.Changeset.activate_mfa_enrollment(loaded)
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, _changes} -> delivery
      {:error, reason} -> {:error, reason}
    end
  end

  defp finalize_mfa_enrollment_delivery(%UserToken{} = pending, user_id, delivery) do
    UserToken.Query.by_id(pending.id)
    |> UserToken.Query.by_user_id(user_id)
    |> UserToken.Query.by_context("mfa_enrollment_pending")
    |> Repo.delete_all()

    delivery
  end

  @doc """
  Consumes the emailed MFA-enrollment code and returns a short-lived opaque
  proof. Verification spends the shared current-inbox attempt budget, so
  replacing this token or switching to email-change verification cannot reset
  the guessing window. `enable_mfa/5` rechecks the proof against the locked
  current user row before writing the new factor.
  """
  def verify_mfa_enrollment_code(
        code,
        %Subject{actor: %Users.User{id: id}} = subject
      )
      when is_binary(code) do
    with {:ok, user} <- Users.fetch_user_by_id(id),
         :ok <- ensure_mfa_not_enabled(user),
         :ok <- ensure_mfa_enrollment_email(user),
         :ok <-
           throttle_security_attempt(
             user,
             :inbox_step_up,
             @inbox_step_up_limit,
             @inbox_step_up_window_ms,
             subject.context
           ) do
      case consume_mfa_enrollment_code(code, user.id) do
        {:ok, verified_user} ->
          {:ok, mfa_enrollment_proof(verified_user)}

        # A wrong or expired emailed code leaves an audit trail so grinding a
        # hijacked session toward MFA enrollment is visible.
        {:error, reason} ->
          Audit.log_for_user(user, "user.mfa_enrollment_failed",
            context: subject.context,
            payload: %{reason: to_string(reason)}
          )

          {:error, reason}
      end
    end
  end

  defp ensure_mfa_not_enabled(%Users.User{mfa_enabled_at: nil}), do: :ok
  defp ensure_mfa_not_enabled(%Users.User{}), do: {:error, :mfa_already_enabled}

  defp ensure_mfa_enrollment_email(%Users.User{email: email})
       when is_binary(email) and email != "",
       do: :ok

  defp ensure_mfa_enrollment_email(%Users.User{}), do: {:error, :email_unavailable}

  defp consume_mfa_enrollment_code(code, user_id) do
    Multi.new()
    |> Multi.run(:user, fn repo, _changes ->
      with {:ok, user} <- Users.fetch_and_lock_user_by_id(user_id, repo),
           :ok <- ensure_mfa_not_enabled(user),
           :ok <- ensure_mfa_enrollment_email(user) do
        {:ok, user}
      end
    end)
    |> Multi.run(:token, fn repo, %{user: user} ->
      loaded_token_query =
        UserToken.Query.by_user_id(user.id)
        |> UserToken.Query.by_context("mfa_enrollment")
        |> UserToken.Query.not_expired("mfa_enrollment")
        |> UserToken.Query.with_attempts_remaining()
        |> UserToken.Query.lock_for_update()

      case repo.fetch(loaded_token_query, UserToken.Query) do
        {:ok, loaded_token} -> {:ok, loaded_token}
        {:error, :not_found} -> {:error, :invalid}
      end
    end)
    |> Multi.run(:outcome, fn repo, %{user: user, token: token} ->
      cond do
        not mfa_enrollment_token_current?(token, user) ->
          {:ok, _} = repo.delete(token)
          {:ok, {:error, :invalid}}

        Crypto.secure_compare(Crypto.hash(code), token.token) ->
          {:ok, _} = repo.delete(token)
          {:ok, {:ok, token}}

        true ->
          {:ok, _} = repo.update(UserToken.Changeset.decrement_attempts(token))
          {:ok, {:error, :invalid}}
      end
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{user: user, outcome: {:ok, _token}}} -> {:ok, user}
      {:ok, %{outcome: {:error, :invalid}}} -> {:error, :invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mfa_enrollment_token_current?(%UserToken{} = token, %Users.User{} = user) do
    token.sent_to == user.email and
      token.metadata["user_updated_at"] == DateTime.to_iso8601(user.updated_at)
  end

  @doc """
  Generates a fresh TOTP secret for the user. Caller is responsible for
  displaying the QR code; nothing is persisted until `enable_mfa/5` confirms
  both the current-inbox proof and the authenticator code.
  """
  def generate_mfa_secret, do: Crypto.totp_secret()

  # 10 recovery codes is the de facto standard (matches GitHub, Google
  # Workspace, etc). Returned in plaintext exactly once at enable-time;
  # we only persist the digests. Each code's shape (length, encoding,
  # digest) is `Crypto.mfa_recovery_code/0`'s concern.
  @recovery_code_count 10

  @doc """
  Enable TOTP for the caller after a current-inbox proof from
  `verify_mfa_enrollment_code/2`. Verifies the proof against the locked current
  user row and the OTP against the proposed secret before flipping the bit;
  returns the freshly-generated **recovery codes** (plaintext, 10 single-use
  base32 strings) along with the user — show these once and never again. The
  plaintext leaves this function and the DB never sees it.

  `presented_digest` is the stored token digest of the browser session
  completing enrollment (the raw cookie never reaches this layer).
  The user enrollment, audit rows, and that exact same-user live session's local
  proof stamp commit atomically, so recovery codes are never emitted for an
  enrollment whose browser cannot continue.
  """
  def enable_mfa(
        secret,
        otp,
        proof,
        presented_digest,
        %Subject{actor: %Users.User{} = user} = subject
      )
      when is_binary(secret) and is_binary(otp) and is_binary(proof) and
             is_binary(presented_digest) do
    with {:ok, payload} <- verify_mfa_enrollment_proof_for_user(proof, user),
         true <- Crypto.valid_totp?(secret, otp) do
      {plain_codes, digests} = generate_recovery_codes()

      Multi.new()
      |> Multi.run(:user, fn repo, _changes ->
        with {:ok, loaded_user} <- Users.fetch_and_lock_user_by_id(user.id, repo),
             :ok <- ensure_mfa_enrollment_state_current(loaded_user, payload) do
          {:ok, loaded_user}
        end
      end)
      |> Multi.run(:session, fn repo, %{user: loaded_user} ->
        fetch_and_lock_current_session(presented_digest, loaded_user.id, repo)
      end)
      |> Multi.run(:enabled_at, fn _repo, _changes -> {:ok, DateTime.utc_now()} end)
      |> Multi.merge(fn %{user: loaded_user, session: session, enabled_at: enabled_at} ->
        Multi.new()
        |> Users.put_mfa_enrollment(
          loaded_user,
          secret,
          enabled_at,
          digests,
          subject.context
        )
        |> Multi.update(
          :mfa_session,
          UserToken.Changeset.local_mfa_verified(session, enabled_at)
        )
      end)
      |> Repo.commit_multi()
      |> case do
        {:ok, %{mfa_enrollment: updated}} -> {:ok, updated, plain_codes}
        {:error, reason} -> {:error, reason}
      end
    else
      false -> {:error, :invalid_otp}
      {:error, reason} -> {:error, reason}
    end
  end

  def enable_mfa(_, _, _, _, %Subject{}), do: {:error, :mfa_enrollment_proof_stale}

  defp fetch_and_lock_current_session(presented_digest, user_id, repo)
       when is_binary(presented_digest) and is_binary(user_id) do
    UserToken.Query.by_token_digest(presented_digest)
    |> UserToken.Query.by_user_id(user_id)
    |> UserToken.Query.by_context("session")
    |> UserToken.Query.not_expired("session")
    |> UserToken.Query.lock_for_update()
    |> repo.fetch(UserToken.Query)
    |> case do
      {:ok, %UserToken{} = session} -> {:ok, session}
      {:error, :not_found} -> {:error, :session_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mfa_enrollment_proof(%Users.User{} = user) do
    Phoenix.Token.sign(
      mfa_proof_secret(),
      @mfa_enrollment_proof_salt,
      mfa_enrollment_proof_payload(user)
    )
  end

  defp mfa_enrollment_proof_payload(%Users.User{} = user),
    do: {:mfa_enrollment, user.id, user.email, user.updated_at}

  defp verify_mfa_enrollment_proof_for_user(proof, %Users.User{id: user_id}) do
    case Phoenix.Token.verify(mfa_proof_secret(), @mfa_enrollment_proof_salt, proof,
           max_age: @mfa_enrollment_proof_max_age_seconds
         ) do
      {:ok, {:mfa_enrollment, ^user_id, email, %DateTime{}} = payload}
      when is_binary(email) ->
        {:ok, payload}

      _other ->
        {:error, :mfa_enrollment_proof_stale}
    end
  end

  defp ensure_mfa_enrollment_state_current(
         %Users.User{mfa_enabled_at: nil} = user,
         payload
       ) do
    if mfa_enrollment_proof_payload(user) == payload,
      do: :ok,
      else: {:error, :mfa_enrollment_proof_stale}
  end

  defp ensure_mfa_enrollment_state_current(%Users.User{}, _payload),
    do: {:error, :mfa_already_enabled}

  @doc """
  Disable TOTP for the caller after verifying a current TOTP or recovery code.
  The user is re-fetched before the factor check, and both verification paths
  validate against the current row under a lock.

  Sessions survive: a session's `mfa_verified_at` is bound to the enrollment it
  proved (`session_mfa_verified?/2`), so tearing the factor down already strips
  every live session of its second-factor claim without signing anyone out.

  Their live SOCKETS do not survive, because a mounted socket decided its gates
  once and holds a `%Subject{}` built from the old enrollment: an already-open
  `/ops/live` would stay usable until its next mount, and the profile socket
  that initiated this would keep stamping a stale `mfa` onto later audit rows.
  Dropping the sockets makes each one reconnect, remount, and re-decide against
  the rebuilt Subject — the cookie is still valid, so nobody is signed out.

  Returns {:ok, user} on success, {:error, :invalid_code | :replay} when the
  factor is rejected, {:error, :rate_limited} once the shared per-user MFA
  attempt window is exhausted, or the underlying update error.
  """
  def disable_mfa(code, %Subject{actor: %Users.User{id: id}} = subject)
      when is_binary(code) do
    code = String.trim(code)

    with {:ok, user} <- Users.fetch_user_by_id(id),
         {:ok, _verified} <- verify_current_mfa_factor(user, code, subject.context) do
      # Captured before the write and broadcast after it, the same order the
      # sibling revocation paths use, so every "this credential changed, re-decide"
      # site reads as one shape. The broadcast is a best-effort side effect on the
      # way out rather than a transaction hook, which keeps this entry point safe
      # to call from a caller that already holds a transaction.
      socket_topics = capture_live_socket_topics(user)

      case Users.update_user_mfa(id, nil, nil, [],
             audit: &Audit.user_changesets(&1, "user.mfa_disabled", context: subject.context)
           ) do
        {:ok, disabled_user} ->
          disconnect_live_socket_topics(socket_topics)
          {:ok, disabled_user}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :invalid} -> {:error, :invalid_code}
      {:error, :not_found} -> {:error, :invalid_code}
      {:error, reason} -> {:error, reason}
    end
  end

  def disable_mfa(_, %Subject{}), do: {:error, :invalid_code}

  defp verify_current_mfa_factor(user, code, context) do
    if Regex.match?(~r/\A\d{6}\z/, code) do
      verify_mfa(user, code, context)
    else
      consume_mfa_recovery_code(user, code, context)
    end
  end

  @doc """
  Regenerate the recovery code set after proving a current TOTP or recovery
  code. Invalidates the prior codes and returns the new plaintext set once.
  Verification spends the shared MFA attempt budget; the final replacement
  also requires MFA to remain enabled on the locked current row.
  """
  def regenerate_mfa_recovery_codes(
        code,
        %Subject{actor: %Users.User{id: id}} = subject
      )
      when is_binary(code) do
    code = String.trim(code)

    with {:ok, user} <- Users.fetch_user_by_id(id),
         :ok <- ensure_mfa_enabled(user),
         :ok <- throttle_mfa_challenge(user, subject.context) do
      factor = current_mfa_factor(code)
      {plain_codes, digests} = generate_recovery_codes()

      id
      |> Users.regenerate_user_mfa_recovery_codes(factor, digests,
        audit:
          &Audit.user_changesets(&1, "user.mfa_recovery_codes_regenerated",
            context: subject.context
          )
      )
      |> case do
        {:ok, updated} ->
          {:ok, updated, plain_codes}

        {:error, :invalid} ->
          Audit.log_for_user(user, "user.mfa_failed",
            context: subject.context,
            payload: %{reason: regeneration_failure_reason(factor)}
          )

          {:error, :invalid_code}

        {:error, :replay} ->
          Audit.log_for_user(user, "user.mfa_failed",
            context: subject.context,
            payload: %{reason: "replay"}
          )

          {:error, :replay}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :not_found} -> {:error, :invalid_code}
      {:error, reason} -> {:error, reason}
    end
  end

  def regenerate_mfa_recovery_codes(_, %Subject{}), do: {:error, :invalid_code}

  defp ensure_mfa_enabled(%Users.User{mfa_enabled_at: %DateTime{}}), do: :ok
  defp ensure_mfa_enabled(%Users.User{}), do: {:error, :mfa_not_enabled}

  defp current_mfa_factor(code) do
    if Regex.match?(~r/\A\d{6}\z/, code) do
      {:totp, code}
    else
      digest = code |> String.downcase() |> Crypto.hash()
      {:recovery_code, digest}
    end
  end

  defp regeneration_failure_reason({:totp, _code}), do: "invalid_otp"
  defp regeneration_failure_reason({:recovery_code, _digest}), do: "invalid_recovery_code"

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

  # A newly inserted row is deliberately born expired. The first locked read
  # resets it from the database's clock, avoiding any dependency on an app
  # node's wall clock while still using a normal schema insert.
  @expired_security_window ~U[2000-01-01 00:00:00.000000Z]

  @doc """
  Internal — spend one attempt from a durable per-user security window.

  Returns `:ok` through the configured limit. The first rejected attempt is
  `{:error, :rate_limited, :exhausted}` and advances the stored count to
  `limit + 1`; later rejects saturate there as `:capped`. Any persistence error
  is `:store_unavailable`, which callers reject exactly like exhaustion.

  The row lock and database clock make the budget atomic across Portal nodes.
  The test-only rate-limit switch still bypasses it so unrelated async tests do
  not share credential budgets.
  """
  def check_security_attempt(user, scope, limit, window_ms, context \\ %RequestContext{})

  def check_security_attempt(%Users.User{id: user_id} = user, scope, limit, window_ms, context)
      when scope in @security_attempt_scopes and
             is_integer(limit) and limit > 0 and is_integer(window_ms) and window_ms > 0 and
             is_struct(context, RequestContext) do
    if Emisar.Config.get_env(:emisar, :rate_limit_enabled, true) do
      do_check_security_attempt(user, user_id, scope, limit, window_ms, context)
    else
      :ok
    end
  end

  defp do_check_security_attempt(user, user_id, scope, limit, window_ms, context) do
    commit_security_attempt(user, user_id, scope, limit, window_ms, context)
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, :rate_limited, :store_unavailable}
  end

  defp commit_security_attempt(user, user_id, scope, limit, window_ms, context) do
    Multi.new()
    |> Multi.run(:ensure_window, fn repo, _changes ->
      attrs = %{
        id: Repo.generate_id(),
        user_id: user_id,
        scope: scope,
        attempt_count: 0,
        window_started_at: @expired_security_window,
        window_expires_at: @expired_security_window,
        inserted_at: @expired_security_window,
        updated_at: @expired_security_window
      }

      case repo.insert_all(SecurityAttemptWindow, [attrs],
             on_conflict: :nothing,
             conflict_target: [:user_id, :scope]
           ) do
        {_count, nil} -> {:ok, :ready}
      end
    end)
    |> Multi.run(:window, fn repo, _changes ->
      window_query =
        SecurityAttemptWindow.Query.by_user_and_scope(user_id, scope)
        |> SecurityAttemptWindow.Query.lock_for_update()

      case repo.fetch(window_query, SecurityAttemptWindow.Query) do
        {:ok, window} ->
          database_now =
            SecurityAttemptWindow.Query.by_user_and_scope(user_id, scope)
            |> SecurityAttemptWindow.Query.select_database_time()
            |> repo.one!()

          {:ok, {window, database_now}}

        {:error, :not_found} ->
          {:error, :store_unavailable}
      end
    end)
    |> Multi.run(:attempt, fn repo, %{window: {window, database_now}} ->
      {changeset, outcome} =
        SecurityAttemptWindow.Changeset.advance(window, database_now, limit, window_ms)

      case repo.update(changeset) do
        {:ok, updated} -> {:ok, %{window: updated, outcome: outcome}}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> maybe_log_security_attempt_exhausted(user, scope, limit, window_ms, context)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{attempt: %{outcome: :allowed}}} -> :ok
      {:ok, %{attempt: %{outcome: :exhausted}}} -> {:error, :rate_limited, :exhausted}
      {:ok, %{attempt: %{outcome: :capped}}} -> {:error, :rate_limited, :capped}
      {:error, _reason} -> {:error, :rate_limited, :store_unavailable}
    end
  end

  @security_attempt_exhausted_events %{
    mfa_challenge: "user.mfa_rate_limited",
    mfa_enrollment_issue: "user.mfa_rate_limited",
    email_change_issue: "user.email_change_rate_limited",
    inbox_step_up: "user.inbox_step_up_rate_limited",
    oidc_identity_step_up_issue: "user.oidc_identity_step_up_rate_limited"
  }

  defp maybe_log_security_attempt_exhausted(
         multi,
         %Users.User{} = user,
         scope,
         limit,
         window_ms,
         %RequestContext{} = context
       ) do
    log_security_attempt_exhausted(
      multi,
      user,
      Map.fetch!(@security_attempt_exhausted_events, scope),
      scope,
      limit,
      window_ms,
      context
    )
  end

  defp log_security_attempt_exhausted(
         multi,
         user,
         event_type,
         scope,
         limit,
         window_ms,
         context
       ) do
    Audit.Multi.log_for_user(multi, :rate_limit_audit, user, event_type,
      user_fn: fn
        %{attempt: %{outcome: :exhausted}} -> user
        _changes -> nil
      end,
      payload_fn: fn _changes ->
        %{
          scope: Atom.to_string(scope),
          attempt_limit: limit,
          window_seconds: div(window_ms, 1_000)
        }
      end,
      extra: [context: context]
    )
  end

  @doc """
  Verifies the sign-in second factor — `{:totp, otp}` or `{:recovery_code,
  code}` — behind the shared per-user fixed-window attempt cap, so no challenge
  caller can be used as an unbounded guessing oracle. The cap is keyed by user id
  (server-side), so a page reload or a fresh socket can't reset it, and every
  attempt counts toward the same window regardless of factor or surface.

  Pre-Subject — this is the sign-in second factor, so it takes the
  partially-authenticated `%Users.User{}` (no tenant resolved yet). Returns
  `{:ok, proof}` — an opaque term bound to the enrollment that was just
  verified, which `complete_magic_link_mfa_sign_in/4` re-checks against the
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
  Verifies a local-MFA challenge for an already-authenticated user. The Subject
  is the authorization boundary: the factor is always checked against its actor
  and the attempt audit uses its request context.
  """
  def verify_current_session_mfa_challenge(
        factor,
        %Subject{actor: %Users.User{} = user, context: context}
      ) do
    verify_mfa_challenge(user, factor, context)
  end

  def verify_current_session_mfa_challenge(_, %Subject{}), do: {:error, :unauthorized}

  @doc """
  Internal — wrap a just-verified local factor or dedicated SSO
  reauthentication in the short-lived, purpose-bound handoff that Accounts
  consumes for one member MFA reset. The target's exact enrollment epoch and
  row version make a successful reset, disable, or re-enrollment stale the
  proof instead of turning it into a reusable administrator capability.
  """
  def issue_member_mfa_reset_proof(
        %Accounts.Membership{} = membership,
        %Users.User{
          id: target_user_id,
          mfa_enabled_at: %DateTime{} = target_mfa_enabled_at,
          updated_at: %DateTime{} = target_updated_at
        },
        source,
        actor_session_token_digest,
        %Subject{
          actor: %Users.User{id: actor_id},
          account: %Accounts.Account{id: account_id},
          membership_id: actor_membership_id
        }
      )
      when membership.account_id == account_id and membership.user_id == target_user_id and
             is_binary(actor_membership_id) and is_binary(actor_session_token_digest) do
    with {:ok, source} <- member_mfa_reset_source(source) do
      payload = %{
        actor_id: actor_id,
        actor_membership_id: actor_membership_id,
        account_id: account_id,
        target_membership_id: membership.id,
        target_user_id: target_user_id,
        target_mfa_enabled_at: target_mfa_enabled_at,
        target_updated_at: target_updated_at,
        actor_session_token_digest: actor_session_token_digest,
        source: source
      }

      {:ok,
       Phoenix.Token.sign(
         mfa_proof_secret(),
         @member_mfa_reset_proof_salt,
         {:member_mfa_reset, 1, payload}
       )}
    end
  end

  def issue_member_mfa_reset_proof(_, _, _, _, %Subject{}),
    do: {:error, :mfa_reset_proof_stale}

  @doc "Internal — verify and decode the reset-specific handoff; generic MFA proofs use another salt."
  def verify_member_mfa_reset_proof(proof) when is_binary(proof) do
    case Phoenix.Token.verify(mfa_proof_secret(), @member_mfa_reset_proof_salt, proof,
           max_age: @member_mfa_reset_proof_max_age_seconds
         ) do
      {:ok, {:member_mfa_reset, 1, payload}} when is_map(payload) ->
        {:ok, payload}

      _other ->
        {:error, :mfa_reset_proof_stale}
    end
  end

  def verify_member_mfa_reset_proof(_proof), do: {:error, :mfa_reset_proof_stale}

  @doc "Internal — recheck the embedded local proof against the actor row locked by Accounts."
  def verify_local_member_mfa_reset_source({:local, proof}, %Users.User{} = user) do
    case verify_mfa_proof(proof) do
      {:ok, payload} ->
        if payload == mfa_proof_payload(user),
          do: :ok,
          else: {:error, :mfa_reset_proof_stale}

      _other ->
        {:error, :mfa_reset_proof_stale}
    end
  end

  def verify_local_member_mfa_reset_source(_, %Users.User{}),
    do: {:error, :mfa_reset_proof_stale}

  @doc "Internal — lock the exact live actor session bound into a member-MFA-reset proof."
  def lock_member_mfa_reset_session(
        repo,
        token_digest,
        actor_id,
        source
      )
      when is_binary(token_digest) and is_binary(actor_id) do
    result =
      UserToken.Query.by_token_digest(token_digest)
      |> UserToken.Query.by_user_id(actor_id)
      |> UserToken.Query.by_context("session")
      |> UserToken.Query.not_expired("session")
      |> UserToken.Query.lock_for_update()
      |> repo.fetch(UserToken.Query)

    with {:ok, %UserToken{} = session} <- result,
         :ok <- ensure_member_mfa_reset_session_source(session, source) do
      {:ok, session}
    else
      _other -> {:error, :mfa_reset_proof_stale}
    end
  end

  @doc """
  Internal — finish an already-authenticated browser's local-MFA step-up. The
  signed `proof` came from `verify_mfa_challenge/3`; this transaction re-locks
  its user and rechecks the exact enrollment before touching the session. The
  `presented_digest` must name one live same-user session, so a
  stale/revoked/foreign session cannot be upgraded or resurrected.

  Factor consumption and this handoff are deliberately two stages, matching the
  magic-link MFA completion path. A rare session race may spend one TOTP bucket
  or recovery code but grants nothing; the operator can retry or sign in again.
  """
  def complete_current_session_mfa(
        proof,
        presented_digest,
        %Subject{actor: %Users.User{id: subject_user_id}, context: context}
      )
      when is_binary(proof) and is_binary(presented_digest) do
    case mfa_proof_user_id(proof) do
      ^subject_user_id ->
        Multi.new()
        |> Multi.run(:user, fn repo, _changes ->
          lock_signing_in_user(subject_user_id, proof, repo)
        end)
        |> Multi.run(:session, fn repo, %{user: user} ->
          fetch_and_lock_current_session(presented_digest, user.id, repo)
        end)
        |> Multi.update(:mfa_session, fn %{user: user, session: session} ->
          UserToken.Changeset.local_mfa_verified(session, user.mfa_enabled_at)
        end)
        # A step-up upgrades a LIVE session's assurance and used to leave no
        # trace: "when did this session become MFA-verified" was answerable only
        # from the `auth_user_tokens` row, which the retention sweep deletes.
        # The row commits with the stamp, so a rolled-back stamp claims nothing.
        |> Audit.Multi.log_for_user(:audit, nil, "user.mfa_verified",
          user_fn: & &1.user,
          extra: [context: context, payload: %{session_verified: true}]
        )
        |> Repo.commit_multi()
        |> case do
          {:ok, %{mfa_session: session}} -> {:ok, session}
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:error, :mfa_proof_stale}
    end
  end

  def complete_current_session_mfa(_, _, %Subject{}), do: {:error, :mfa_proof_stale}

  defp member_mfa_reset_source({:local, proof}) when is_binary(proof),
    do: {:ok, {:local, proof}}

  defp member_mfa_reset_source(
         {:sso,
          %{
            provider_id: provider_id,
            identity_id: identity_id,
            provider_identifier: provider_identifier,
            namespace: {issuer, client_id, identifier_claim},
            auth_time: auth_time
          }}
       )
       when is_binary(provider_id) and is_binary(identity_id) and
              is_binary(provider_identifier) and is_binary(issuer) and is_binary(client_id) and
              identifier_claim in [:sub, :oid] and is_integer(auth_time) do
    {:ok,
     {:sso,
      %{
        provider_id: provider_id,
        identity_id: identity_id,
        provider_identifier: provider_identifier,
        namespace: {issuer, client_id, identifier_claim},
        auth_time: auth_time
      }}}
  end

  defp member_mfa_reset_source(_source), do: {:error, :mfa_reset_proof_stale}

  defp ensure_member_mfa_reset_session_source(%UserToken{}, {:local, _proof}), do: :ok

  defp ensure_member_mfa_reset_session_source(
         %UserToken{auth_method: :sso, user_identity_id: identity_id},
         {:sso, %{identity_id: identity_id}}
       )
       when is_binary(identity_id),
       do: :ok

  defp ensure_member_mfa_reset_session_source(%UserToken{}, _source),
    do: {:error, :mfa_reset_proof_stale}

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

  defp throttle_mfa_challenge(%Users.User{} = user, context) do
    throttle_security_attempt(
      user,
      :mfa_challenge,
      @mfa_challenge_attempt_limit,
      @mfa_challenge_attempt_window_ms,
      context
    )
  end

  defp throttle_security_attempt(user, scope, limit, window_ms, context) do
    case check_security_attempt(
           user,
           scope,
           limit,
           window_ms,
           context
         ) do
      :ok -> :ok
      {:error, :rate_limited, _reason} -> {:error, :rate_limited}
    end
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
    with :ok <- throttle_mfa_challenge(user, context) do
      # The OTP is NOT validated against this (possibly stale) struct's secret —
      # `verify_and_consume_mfa` re-reads the row under a lock and validates +
      # consumes there, so a secret rotated/disabled mid-verify can't slip an old
      # code through. We only AUDIT here from the caller's user.
      case Users.verify_and_consume_mfa(user.id, otp, []) do
        {:ok, %Users.User{} = verified} ->
          # Both misses below are audited. Without this the trail carried every
          # FAILED second factor and none of the accepted ones, so an
          # investigator could not answer "did this person actually pass MFA,
          # and when" from the log at all.
          Audit.log_for_user(user, "user.mfa_verified",
            context: context,
            payload: %{factor: "totp"}
          )

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
    with :ok <- throttle_mfa_challenge(user, context) do
      digest = raw |> String.trim() |> String.downcase() |> Crypto.hash()

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
