defmodule Emisar.Auth do
  @moduledoc """
  Authentication: workspace sessions, the emailed sign-in and sign-up codes,
  SSO sign-in completion, and the MFA scaffold.

  Every session and code belongs to exactly one workspace Member; a sign-up
  code alone belongs to none until its workspace exists. All token types share
  `auth_user_tokens` storage; `context` disambiguates semantics + validity window.
  """
  use Supervisor
  alias Ecto.Multi
  alias Emisar.{Accounts, Audit, Billing, Mailers}
  alias Emisar.Auth.MfaFacts
  alias Emisar.Auth.Role
  alias Emisar.Auth.SecurityAttemptWindow
  alias Emisar.Auth.SessionFacts
  alias Emisar.Auth.SessionSubject
  alias Emisar.Auth.Subject
  alias Emisar.Auth.UserToken
  alias Emisar.Crypto
  alias Emisar.Repo
  alias Emisar.RequestContext
  alias Emisar.SSO
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

  # -- Current account authority ---------------------------------------

  @doc """
  Refreshes the exact account identity before an operational read or action.

  The original permissions remain an upper bound: a role change can remove
  authority, never restore permissions the caller deliberately omitted. Checks
  the supplied permission, permission list, or `{:one_of, permissions}` before
  any database access, then checks it again against the current identity.

  Returns `{:ok, subject}` with current actor/account/role facts and preserved
  session provenance, or `{:error, :unauthorized}`. Callers must use the returned
  subject for subsequent row scoping. This does not replace session validation,
  current target access checks, or mutation-specific locking.
  """
  def fetch_current_subject(
        required_permissions,
        %Subject{actor: %Accounts.Membership{}} = subject
      ),
      do: __MODULE__.Authorizer.fetch_authorized_subject(subject, required_permissions)

  def fetch_current_subject(required_permissions, %Subject{} = subject) do
    with :ok <- __MODULE__.Authorizer.ensure_has_permissions(subject, required_permissions),
         {:ok, current_subject} <- __MODULE__.CurrentSubject.fetch(subject),
         :ok <-
           __MODULE__.Authorizer.ensure_has_permissions(current_subject, required_permissions) do
      {:ok, current_subject}
    end
  end

  # -- Sessions ---------------------------------------------------------

  @doc """
  Internal — `EmisarWeb.UserAuth` resolves the cookie entry for the workspace in
  the URL; the session token IS the credential, so there's no Subject yet.
  Returns `{:ok, %UserToken{}}` only when the row passes the per-request
  predicate (`UserToken.Query.authorized/1`) inside `account_id`, with its
  Member, workspace and SSO route preloaded — the facts
  `Subject.for_session/2` builds from. A token presented under another
  workspace, an expired or unknown token, and a session whose Member,
  workspace or SSO route no longer qualifies are all `{:error, :not_found}`.
  """
  def fetch_session_by_token(token, account_id) when is_binary(token) do
    if Repo.valid_uuid?(account_id) do
      UserToken.Query.authorized()
      |> UserToken.Query.by_token_digest(Crypto.hash(token))
      |> UserToken.Query.by_account_id(account_id)
      |> UserToken.Query.with_preloaded_authority()
      |> Repo.fetch(UserToken.Query)
    else
      {:error, :not_found}
    end
  end

  @doc """
  When a workspace session stops authenticating: the absolute expiry the
  per-request predicate applies, so a connected LiveView can leave at that
  instant instead of holding authority the row no longer has. Nothing extends it.
  """
  def session_expires_at(%UserToken{context: "session", inserted_at: %DateTime{} = minted_at}),
    do: UserToken.Query.session_expires_at(minted_at)

  @doc """
  Internal — the live sessions behind a browser's cookie entries, in one query.
  `entries` are `{account_id, raw_token}` pairs, at most six; each matches only
  its own workspace's row, and an entry that no longer passes the per-request
  predicate is simply absent, so the boundary can drop it. Possession of the
  cookie is the credential, so no Subject. Returns `{:ok, [%UserToken{}]}` with
  the same preloads as `fetch_session_by_token/2`.
  """
  def list_live_sessions(entries) when is_list(entries) do
    pairs =
      for {account_id, token} <- entries, Repo.valid_uuid?(account_id), is_binary(token) do
        {account_id, Crypto.hash(token)}
      end

    sessions =
      UserToken.Query.authorized()
      |> UserToken.Query.by_entries(pairs)
      |> UserToken.Query.with_preloaded_authority()
      |> Repo.all()

    {:ok, sessions}
  end

  @doc """
  The exact live session a Member Subject acts through, re-read through the
  per-request predicate, with its Member and workspace preloaded. Returns
  `{:ok, %UserToken{}}`, or `{:error, :unauthorized}` once that session, its
  Member or its workspace no longer authenticates, and for a Subject that is not
  a Member acting through a session.
  """
  defdelegate fetch_current_session(subject), to: SessionSubject, as: :fetch_session

  @doc """
  Internal — SSO sign-in completion: `SSO.complete_auth/3` verified the
  callback and resolved `membership`, `identity` and `provider`; this mints the
  session for that one Member, so there's no Subject yet. Locks the workspace,
  its SSO entitlement, the provider (still enabled, still at the issuer that
  verified the callback), the identity (still bound to this Member with the
  same subject) and the Member, in that order, then inserts a session that
  freezes the route it proved. The locked provider alone decides the IdP MFA
  stamp. Records the Member's activity and audits `user.signed_in`.

  `browser_id` is the browser's own random id from its session cookie; the
  session stores only its digest, so signing out of this browser ends every
  session it minted (`complete_browser_sign_out/3`).

  Returns `{:ok, raw_token, mfa?}` — the cookie value and whether the provider
  satisfies MFA — or `{:error, :account_disabled | :provider_disabled |
  :membership_unavailable}`.
  """
  def complete_sso_sign_in(
        %Accounts.Membership{} = membership,
        %SSO.UserIdentity{} = identity,
        %SSO.IdentityProvider{} = provider,
        browser_id,
        %RequestContext{} = context
      )
      when is_binary(browser_id) do
    {token, digest} = Crypto.session_token()

    Multi.new()
    |> Multi.run(:account, fn repo, _changes ->
      case Accounts.fetch_and_lock_account(provider.account_id, repo: repo) do
        {:ok, account} -> {:ok, account}
        {:error, :not_found} -> {:error, :account_disabled}
      end
    end)
    |> SSO.put_sign_in_authority(provider.account_id, identity.id, identity.provider_identifier)
    # The callback verified the ID token against `provider`. A provider pointed
    # at another issuer since then must not mint a session under the new one.
    |> Multi.run(:verified_provider, fn _repo, %{sso_provider: locked_provider} ->
      if locked_provider.id == provider.id and locked_provider.issuer == provider.issuer,
        do: {:ok, locked_provider},
        else: {:error, :provider_disabled}
    end)
    |> Multi.run(:membership, fn repo, %{sso_identity: locked_identity} ->
      with true <- locked_identity.membership_id == membership.id,
           {:ok, locked_membership} <-
             Accounts.fetch_and_lock_active_membership(repo, provider.account_id, membership.id) do
        {:ok, locked_membership}
      else
        _ -> {:error, :membership_unavailable}
      end
    end)
    |> Multi.insert(:token, fn changes ->
      UserToken.Changeset.sso_session(
        changes.membership,
        digest,
        Crypto.hash(browser_id),
        request_metadata(context),
        changes.sso_identity,
        changes.verified_provider
      )
    end)
    |> put_sign_in_records("sso", context)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{verified_provider: locked_provider}} -> {:ok, token, locked_provider.satisfies_mfa}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Internal — the browser boundary drops session entries it no longer keeps:
  `:replaced` (a new sign-in to the same workspace took its place), `:evicted`
  (a seventh workspace pushed the oldest entry out of the cookie) or
  `:dead_entry` (it no longer authenticates). Possession of the cookie values is
  the credential, so no Subject. Deletes those session rows in one transaction,
  so a copied cookie never keeps a credential the browser dropped; each one that
  was still live is locked first and recorded as `user.session_revoked` with the
  reason, in its own workspace, while rows that no longer authenticate are
  swept silently. Sockets disconnect after commit. Returns `:ok`, or
  `{:error, reason}` when the transaction fails.
  """
  def revoke_session_tokens(raw_tokens, revocation, %RequestContext{} = context)
      when is_list(raw_tokens) and revocation in [:replaced, :evicted, :dead_entry] do
    digests = raw_token_digests(raw_tokens)
    filter = &UserToken.Query.by_token_digests(&1, digests)

    case end_sessions(filter, &session_revoked_event(&1, revocation, context)) do
      {:ok, _ended_sessions} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp session_revoked_event(%UserToken{} = session, revocation, context) do
    Audit.Events.member_security_event(session.membership, "user.session_revoked", context, %{
      session_id: session.id,
      reason: Atom.to_string(revocation)
    })
  end

  @doc """
  Internal — the voluntary sign-out: `EmisarWeb.UserAuth` presents every raw
  session token in this browser's cookie, and the browser's own `browser_id`,
  and the domain ends them all, in every workspace, together. Every session the
  browser minted is ended, not only those its cookie still names: two tabs that
  signed in at once can leave a session the final cookie never held. Possession
  of the cookie is the credential, so no Subject; each row's own Member is the
  audited actor, never the boundary's snapshot of who is signed in.

  The live sessions are locked first; the deletes and one `user.signed_out`
  row per live session, in that session's workspace, commit together, so a
  browser is never told it signed out on a transaction that rolled back and a
  double-submitted sign-out audits once — the second request waits on the
  locks and then finds nothing live. Expired and no-longer-authorized rows are
  swept silently. Sockets disconnect after commit. A `nil` `browser_id` ends
  only the cookie's own entries.

  Returns `{:ok, [%Accounts.Membership{}]}` — the Members whose live session
  ended, each with its workspace preloaded — or `{:error, reason}` when the
  transaction fails.
  """
  def complete_browser_sign_out(raw_tokens, browser_id, %RequestContext{} = context)
      when is_list(raw_tokens) do
    digests = raw_token_digests(raw_tokens)
    browser_digest = if is_binary(browser_id), do: Crypto.hash(browser_id)
    filter = &UserToken.Query.by_browser(&1, digests, browser_digest)

    case end_sessions(filter, &signed_out_event(&1, context)) do
      {:ok, ended_sessions} -> {:ok, Enum.map(ended_sessions, & &1.membership)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp signed_out_event(%UserToken{} = session, context),
    do: Audit.Events.member_security_event(session.membership, "user.signed_out", context)

  # Ends the session rows `filter` selects. The live ones are locked first, so a
  # racing request that ends the same session waits, then finds it gone and
  # records nothing; each live one gets its audit row in its own workspace, in
  # the deleting transaction. Rows that no longer authenticate are deleted
  # silently. Sockets disconnect after commit. Returns the ended live sessions.
  defp end_sessions(filter, audit_event) do
    live_sessions_query =
      UserToken.Query.authorized()
      |> filter.()
      |> UserToken.Query.with_preloaded_authority()
      |> UserToken.Query.lock_tokens_for_update()

    stored_sessions_query =
      UserToken.Query.by_context("session")
      |> filter.()
      |> UserToken.Query.select_token_digests()

    Multi.new()
    |> Multi.run(:live_sessions, fn repo, _changes -> {:ok, repo.all(live_sessions_query)} end)
    |> Multi.delete_all(:sessions, stored_sessions_query)
    |> Multi.run(:session_audit, fn repo, %{live_sessions: live_sessions} ->
      insert_audit_events(repo, Enum.map(live_sessions, audit_event))
    end)
    |> Repo.commit_multi(after_commit: &disconnect_ended_sessions/1)
    |> case do
      {:ok, %{live_sessions: live_sessions}} -> {:ok, live_sessions}
      {:error, reason} -> {:error, reason}
    end
  end

  defp disconnect_ended_sessions(%{sessions: {_count, digests}}) do
    digests
    |> Enum.map(&live_socket_topic/1)
    |> disconnect_live_sessions()
  end

  @doc """
  Internal — end one Member's every token, sessions and pending codes alike,
  inside the caller's transaction (suspension, removal, a reduced role, an
  admin ending the Member's sessions, an MFA reset). No Subject: the caller
  holds the Member's lock and already authorized the change. DELETE RETURNING
  captures the session sockets for the caller's after-commit disconnect.
  Returns `{:ok, %{count: count, socket_topics: topics}}`.
  """
  def delete_membership_sessions(%Accounts.Membership{} = membership, repo) do
    member_tokens_query = UserToken.Query.by_membership(membership.account_id, membership.id)

    sessions_query =
      member_tokens_query
      |> UserToken.Query.by_context("session")
      |> UserToken.Query.select_token_digests()

    {session_count, digests} = repo.delete_all(sessions_query)
    {code_count, _codes} = repo.delete_all(member_tokens_query)
    revoked_sessions(session_count + code_count, digests)
  end

  @doc """
  Internal — end every session that signed in through these SSO identities,
  inside their owner's transaction (a provider disabled or deleted, a directory
  deprovision). Every other session survives. Returns `{:ok, %{count: count,
  socket_topics: topics}}` for the caller's after-commit disconnect.
  """
  def delete_identity_sessions(identity_ids, repo) when is_list(identity_ids) do
    sessions_query =
      UserToken.Query.by_context("session")
      |> UserToken.Query.by_identity_ids(identity_ids)
      |> UserToken.Query.select_token_digests()

    {count, digests} = repo.delete_all(sessions_query)
    revoked_sessions(count, digests)
  end

  @doc """
  Internal — turning Require SSO on ends the workspace's email-code sessions in
  the same transaction, so an open tab cannot keep authority the policy no
  longer allows; its SSO sessions survive. Returns `{:ok, %{count: count,
  socket_topics: topics}}` for the caller's after-commit disconnect.
  """
  def delete_account_email_sessions(account_id, repo) do
    sessions_query =
      UserToken.Query.by_account_id(account_id)
      |> UserToken.Query.by_context("session")
      |> UserToken.Query.by_auth_method(:magic_link)
      |> UserToken.Query.select_token_digests()

    {count, digests} = repo.delete_all(sessions_query)
    revoked_sessions(count, digests)
  end

  defp revoked_sessions(count, digests),
    do: {:ok, %{count: count, socket_topics: Enum.map(digests, &live_socket_topic/1)}}

  @doc """
  The caller's own Member's active sessions, newest first (Profile's device
  list). Self-service, gated by the caller's live session; the list is that one
  Member's, in that one workspace.

  `presented_digest` is the digest of the caller's own session token: each
  stored digest is compared against it in constant time, so the row making
  this request comes back `current?: true` and no caller has to hash a token
  here. A `nil` (or otherwise non-binary) digest simply marks every row
  `current?: false`.

  Rows project into `%SessionFacts{}` — no token, no digest, no raw metadata —
  so the device list cannot leak credential material. Returns `{:ok,
  [%SessionFacts{}], %Paginator.Metadata{}}`, or `{:error, :unauthorized}` once
  the caller's own session no longer authenticates.
  """
  def list_sessions_for_member(presented_digest, %Subject{} = subject, opts \\ []) do
    with {:ok, current} <- fetch_current_session(subject) do
      presented_digest = presented_session_digest(presented_digest)

      sessions_query =
        UserToken.Query.by_membership(current.account_id, current.membership_id)
        |> UserToken.Query.by_context("session")
        |> UserToken.Query.not_expired("session")

      case Repo.list(sessions_query, UserToken.Query, opts) do
        {:ok, tokens, metadata} ->
          {:ok, Enum.map(tokens, &session_facts(&1, presented_digest)), metadata}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp presented_session_digest(digest) when is_binary(digest), do: digest
  defp presented_session_digest(_digest), do: nil

  defp session_facts(%UserToken{} = token, presented_digest) do
    %SessionFacts{
      id: token.id,
      current?: current_session?(token.token, presented_digest),
      ip_address: session_metadata(token.metadata, "ip_address"),
      user_agent: session_metadata(token.metadata, "user_agent"),
      inserted_at: token.inserted_at,
      auth_method: token.auth_method
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
  sign-out). Self-service, gated by the caller's live session: the delete is
  scoped to the Subject's own Member, so another Member's session id is
  `{:error, :not_found}`. The deleted row returns its digest so only that
  session's LiveView sockets disconnect, after the delete and its
  `user.session_revoked` audit commit. Returns `:ok`, `{:error, :not_found |
  :unauthorized}`, or the audit changeset when the audit is rejected.
  """
  def revoke_session(token_id, %Subject{} = subject) do
    with {:ok, current} <- fetch_current_session(subject) do
      if Repo.valid_uuid?(token_id),
        do: delete_own_session(token_id, current.membership, subject.context),
        else: {:error, :not_found}
    end
  end

  defp delete_own_session(token_id, %Accounts.Membership{} = membership, context) do
    session_query =
      UserToken.Query.by_id(token_id)
      |> UserToken.Query.by_membership(membership.account_id, membership.id)
      |> UserToken.Query.by_context("session")
      |> UserToken.Query.select_token_digests()

    audit =
      Audit.Events.member_security_event(membership, "user.session_revoked", context, %{
        session_id: token_id
      })

    Multi.new()
    |> Multi.delete_all(:sessions, session_query)
    |> Multi.run(:revoked_session_topic, fn
      _repo, %{sessions: {1, [digest]}} ->
        {:ok, live_socket_topic(digest)}

      _repo, _changes ->
        {:error, :not_found}
    end)
    |> Multi.insert(:audit, audit)
    |> Repo.commit_multi(after_commit: &disconnect_revoked_session/1)
    |> case do
      {:ok, _changes} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp disconnect_revoked_session(%{revoked_session_topic: topic}),
    do: disconnect_live_sessions([topic])

  @doc """
  "Sign out everywhere except this device" — ends every session of the caller's
  own Member except the one whose stored digest is `keep_digest` (the caller's
  current session) and disconnects each ended session's LiveView sockets after
  the delete and its `user.other_sessions_revoked` audit commit. Self-service,
  gated by the caller's live session: only that Member's sessions are reached.
  Returns `{:ok, count}` or `{:error, reason}`, never reporting an audit
  rollback as a successful sign-out.
  """
  def revoke_and_disconnect_other_sessions(keep_digest, %Subject{} = subject)
      when is_binary(keep_digest) do
    with {:ok, %UserToken{membership: membership}} <- fetch_current_session(subject) do
      sessions_query =
        UserToken.Query.by_membership(membership.account_id, membership.id)
        |> UserToken.Query.by_context("session")
        |> UserToken.Query.except_token_digest(keep_digest)
        |> UserToken.Query.select_token_digests()

      Multi.new()
      |> Multi.delete_all(:sessions, sessions_query)
      |> Multi.run(:audit, fn
        repo, %{sessions: {count, _digests}} when count > 0 ->
          audit =
            Audit.Events.member_security_event(
              membership,
              "user.other_sessions_revoked",
              subject.context,
              %{count: count}
            )

          repo.insert(audit)

        _repo, _changes ->
          {:ok, nil}
      end)
      |> Repo.commit_multi(after_commit: &disconnect_ended_sessions/1)
      |> case do
        {:ok, %{sessions: {count, _digests}}} -> {:ok, count}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp raw_token_digests(raw_tokens),
    do: for(token <- raw_tokens, is_binary(token), do: Crypto.hash(token))

  defp request_metadata(%RequestContext{} = context),
    do: %{ip_address: context.ip_address, user_agent: context.user_agent}

  # A sign-in is activity in its workspace and an audit row naming its Member.
  defp put_sign_in_records(multi, method, context) do
    multi
    |> Multi.run(:sign_in_activity, fn repo, %{membership: membership} ->
      Accounts.record_sign_in_activity(repo, membership)
    end)
    |> Multi.insert(:sign_in_audit, fn %{membership: membership} ->
      Audit.Events.member_security_event(membership, "user.signed_in", context, %{
        method: method
      })
    end)
  end

  # A deliberate per-row insert: each event is validated and lands in its own
  # workspace, and the committed list is broadcast like any audit step.
  defp insert_audit_events(repo, changesets) do
    Enum.reduce_while(changesets, {:ok, []}, fn changeset, {:ok, events} ->
      case repo.insert(changeset) do
        {:ok, event} -> {:cont, {:ok, [event | events]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  # -- PubSub ----------------------------------------------------------

  @doc """
  Subscribe the caller — a LiveView — to its own session's disconnect topic, so
  revoking exactly that session ends exactly its sockets. Returns `:ok`.
  """
  def subscribe_session(%UserToken{token: digest}) when is_binary(digest),
    do: Emisar.PubSub.subscribe(live_socket_topic(digest))

  @doc """
  Topic name the LiveView socket subscribes to for "this specific
  session was killed" disconnects. Keyed off the digest stored on the
  session row so the topic can be derived from server-side state
  (the raw cookie value is only available to the user's own browser).
  """
  def live_socket_topic(token_digest) when is_binary(token_digest),
    do: "users_sessions:#{Crypto.encode_digest(token_digest)}"

  @doc """
  Internal — broadcast a disconnect to topics a caller captured inside its
  transaction (a topic is derived from its session row, so reading it after
  the delete yields nothing). Best-effort and idempotent.
  """
  def disconnect_live_socket_topics(topics) when is_list(topics),
    do: disconnect_live_sessions(topics)

  @doc "Internal — refresh only the sockets of this exact Member's sessions after a role or policy commit."
  def broadcast_disconnect_for_membership(%Accounts.Membership{} = membership) do
    sessions_query =
      UserToken.Query.by_membership(membership.account_id, membership.id)
      |> UserToken.Query.by_context("session")
      |> UserToken.Query.select_token_digests()

    sessions_query
    |> Repo.all()
    |> Enum.map(&live_socket_topic/1)
    |> disconnect_live_sessions()
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

  # -- Email codes ------------------------------------------------------

  # Online-guess budget for the alphanumeric emailed secret. The nonce carries
  # the real entropy; this caps brute-force by anyone who somehow has it.
  @magic_link_attempts 5
  @magic_link_contexts ["magic_link", "magic_link_verified"]
  @email_code_contexts ["sign_up" | @magic_link_contexts]

  @doc """
  Internal — pre-auth: the email sign-in request for one workspace. Issues a
  split-code token to the active Member of `account` whose verified address is
  `email`, and emails the code and link; the raw secret never leaves Auth, so
  no caller can relay a sign-in credential it didn't earn. The workspace, then
  the Member, are locked and every check repeated before the code is written;
  the code replaces the Member's outstanding one, if any.

  Returns `{:ok, %{token_id: id, nonce: nonce, delivery: delivery}}` — the
  caller keeps `nonce` browser-side (a short-lived cookie) — where `delivery`
  is `{:ok, :queued}`: the email goes out after the request returns, so the
  response takes the same time for an address that gets a code and one that
  gets a decoy. (With `:email_codes_async?` off, as in tests, the send is inline
  and `delivery` is `{:ok, :sent}`, `{:ok, :suppressed}` or `{:error, reason}`.)
  An unknown, unverified or suspended address, one that is a Member elsewhere
  but not here, and a workspace that does not accept email sign-in
  (`Accounts.email_sign_in_allowed?/1`) are all `{:error, :not_found}`; the
  boundary answers with `magic_link_decoy/0`, so the response is the same.
  """
  def request_magic_link(%Accounts.Account{} = account, email, %RequestContext{} = context)
      when is_binary(email) do
    with true <- Accounts.email_sign_in_allowed?(account),
         %Accounts.Membership{} = membership <-
           Accounts.peek_sign_in_membership(account.id, email) do
      issue_and_deliver_magic_link({:sign_in, account.id, membership.id}, context)
    else
      _refused -> {:error, :not_found}
    end
  end

  @doc """
  Internal — invitation acceptance, before anything is proved: the invite token
  is the capability, so there is no Subject. `intent` is
  `Accounts.prepare_invitation_acceptance/2`'s. Sends the split code to the
  invited address only — the pending Member still holding the same invitation
  token — so a forwarded invitation link changes nothing until that mailbox
  proves it; the code carries the acceptance, and completing it accepts. Not
  refused where the workspace requires SSO: there, completing the code hands the
  browser to the invitation's SSO step (`SSO.begin_invitation_sso_sign_in/4`),
  which accepts and signs in.

  Same success shape as `request_magic_link/3`; `{:error, :not_found}` when the
  invitation is no longer pending or its workspace is not active.
  """
  def request_invitation_code(
        %{account_id: _, membership_id: _, token_digest: _, display_name: _} = intent,
        %RequestContext{} = context
      ) do
    issue_and_deliver_magic_link({:invitation, intent}, context)
  end

  @doc """
  Internal — pre-auth self-serve sign-up. Validates the submission
  (`Accounts.validate_sign_up/1`), then sends a split code to its address and
  keeps the intent — the workspace name and the owner's name — on the token,
  server-side. No workspace, Member or slug exists until the code comes back
  (`complete_sign_up/3`). The code replaces any outstanding sign-up code for
  that address.

  Same success shape as `request_magic_link/3`, or `{:error, %Ecto.Changeset{}}`
  for an invalid submission.
  """
  def request_sign_up_code(attrs, %RequestContext{} = context) do
    with {:ok, sign_up} <- Accounts.validate_sign_up(attrs) do
      intent = %{account_name: sign_up.account_name, full_name: sign_up.full_name}
      issue_and_deliver_sign_up_code(sign_up.email, intent, context)
    end
  end

  @doc """
  Internal — the browser asks for a fresh code for the one it holds: `token_id`
  comes from its own cookie. Re-runs the issuance that code came from — an
  email sign-in, an invitation acceptance or a sign-up — with the Member,
  address and intent stored on that code, never new ones from the request, so
  the new code is judged exactly like the first. Only a code still inside its
  window qualifies.

  Same success shape as `request_magic_link/3`; `{:error, :not_found}` when the
  code is gone or expired, or its target no longer qualifies.
  """
  def resend_email_code(prior_token_id, %RequestContext{} = context) do
    case peek_resendable_code(prior_token_id) do
      %UserToken{context: "sign_up"} = code ->
        reissue_and_deliver_sign_up_code(code, context)

      %UserToken{metadata: %{"invitation_token_digest" => _digest}} = code ->
        issue_and_deliver_magic_link({:invitation, stored_invitation(code)}, context)

      %UserToken{} = code ->
        issue_and_deliver_magic_link({:sign_in, code.account_id, code.membership_id}, context)

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Internal — pre-auth web boundary: generates browser state with the same
  UUIDv7 id and nonce shape as a real code request, but no persisted factor.
  The boundary uses it for every refused or unknown request, so the response
  is the same; completion necessarily fails because no token row owns the id.
  """
  def magic_link_decoy do
    {nonce, _secret, _digest} = Crypto.magic_link_token()
    %{token_id: Repo.generate_id(), nonce: nonce}
  end

  @doc "Validity window of an emailed code, in minutes — for the sent-page countdown."
  def magic_link_validity_in_minutes, do: UserToken.Query.magic_link_validity_in_minutes()

  # The token and its audit row commit before the send, so the email is a
  # post-commit side effect the caller reports on rather than a step that can
  # undo an issued factor — a mailer outage must not leave the audit log
  # claiming a code that no longer exists.
  defp issue_and_deliver_magic_link(target, context) do
    {nonce, secret, digest} = Crypto.magic_link_token()

    with {:ok, %{account: account, membership: membership, token: token}} <-
           issue_magic_link(target, digest, context) do
      delivery =
        deliver_code(token.id, fn ->
          Mailers.UserNotifier.deliver_magic_link(membership, token.id, secret, context, account)
        end)

      {:ok, %{token_id: token.id, nonce: nonce, delivery: delivery}}
    end
  end

  # A refused address costs the request nothing, so a code must not hold the
  # response for its send either: a Postmark round trip would tell a caller who
  # times the form which addresses belong to the workspace. The mail goes out on
  # the domain's task supervisor (drained on shutdown) and a failure is logged
  # there. Tests send inline (`:email_codes_async?` false) to observe the outcome.
  defp deliver_code(token_id, send) do
    if Emisar.Config.get_env(:emisar, :email_codes_async?, true) do
      supervisor = Application.fetch_env!(:emisar, :task_supervisor)

      {:ok, _pid} =
        Task.Supervisor.start_child(supervisor, fn -> log_code_delivery(send.(), token_id) end)

      {:ok, :queued}
    else
      send.() |> delivery_outcome()
    end
  end

  # The code's token id ties a failure to the request; the reason is only its
  # label, because a provider's error body can echo the recipient's address.
  defp log_code_delivery({:error, reason}, token_id) do
    Logger.warning(
      "sign-in code not delivered token_id=#{token_id} " <>
        "reason=#{Mailers.UserNotifier.failure_label(reason)}"
    )
  end

  defp log_code_delivery(_sent_or_suppressed, _token_id), do: :ok

  # Mints the split-code token: the caller keeps `nonce` browser-side, the
  # `secret` (a short alphanumeric code) is emailed alongside a link carrying
  # `token_id` + `secret`. Locks the workspace, then the Member, and deletes
  # the Member's prior outstanding code (single outstanding).
  defp issue_magic_link(target, digest, context) do
    Multi.new()
    |> Multi.run(:account, fn repo, _changes ->
      Accounts.fetch_and_lock_account(target_account_id(target), repo: repo)
    end)
    |> Multi.run(:membership, fn repo, %{account: account} ->
      lock_code_recipient(repo, account, target)
    end)
    |> Multi.delete_all(:prior, fn %{membership: membership} ->
      UserToken.Query.by_membership(membership.account_id, membership.id)
      |> UserToken.Query.by_contexts(@magic_link_contexts)
    end)
    |> Multi.insert(:token, fn %{membership: membership} ->
      UserToken.Changeset.magic_link(
        membership,
        digest,
        @magic_link_attempts,
        target_invitation(target)
      )
    end)
    |> Multi.insert(:audit, fn %{membership: membership} ->
      Audit.Events.member_security_event(membership, "user.magic_link_issued", context)
    end)
    |> Repo.commit_multi()
  end

  defp target_account_id({:sign_in, account_id, _membership_id}), do: account_id
  defp target_account_id({:invitation, %{account_id: account_id}}), do: account_id

  defp target_invitation({:sign_in, _account_id, _membership_id}), do: nil
  defp target_invitation({:invitation, intent}), do: intent

  defp lock_code_recipient(repo, %Accounts.Account{} = account, {:sign_in, _, membership_id}) do
    case fetch_and_lock_email_sign_in_member(repo, account, membership_id) do
      {:ok, membership} -> {:ok, membership}
      {:error, _refused} -> {:error, :not_found}
    end
  end

  defp lock_code_recipient(repo, %Accounts.Account{} = account, {:invitation, intent}) do
    Accounts.fetch_and_lock_pending_invitation(
      repo,
      account.id,
      intent.membership_id,
      intent.token_digest
    )
  end

  # The Member an email code signs in: still authorized and still holding the
  # verified address the code is sent to, in a workspace that accepts email
  # sign-in.
  defp fetch_and_lock_email_sign_in_member(repo, %Accounts.Account{} = account, membership_id) do
    with {:ok, membership} <-
           Accounts.fetch_and_lock_active_membership(repo, account.id, membership_id),
         true <- verified_address?(membership) do
      if Accounts.email_sign_in_allowed?(account),
        do: {:ok, membership},
        else: {:error, :sso_required}
    else
      _ -> {:error, :invalid_or_expired}
    end
  end

  defp verified_address?(%Accounts.Membership{email: email, email_verified_at: %DateTime{}})
       when is_binary(email),
       do: true

  defp verified_address?(%Accounts.Membership{}), do: false

  # A sign-up code goes to an address no Member holds yet, so there is no
  # workspace to lock or audit in. One code per address: concurrent starts for
  # the same address serialize on a transaction-scoped advisory lock and each
  # deletes the code before it, so only the last one can complete; the partial
  # unique index on the address backs this up.
  defp issue_and_deliver_sign_up_code(email, intent, context) do
    Multi.new()
    |> Multi.run(:address_lock, fn repo, _changes -> lock_sign_up_address(repo, email) end)
    |> Multi.put(:intent, intent)
    |> commit_and_deliver_sign_up_code(email, context)
  end

  # A resend re-runs the issuance from the intent stored on the code the browser
  # holds, but only while that exact code is still there. Completion consumes
  # the code under its row lock and creates the workspace in the same
  # transaction, so a resend that read the code before that commit and caught up
  # afterwards must find it gone — not reissue a second usable code for a
  # workspace that now exists. The address lock comes first, as in every
  # issuance; the code's row is locked and re-judged behind it.
  defp reissue_and_deliver_sign_up_code(%UserToken{id: prior_id, sent_to: email}, context) do
    Multi.new()
    |> Multi.run(:address_lock, fn repo, _changes -> lock_sign_up_address(repo, email) end)
    |> Multi.run(:prior_code, fn repo, _changes ->
      lock_resendable_sign_up_code(repo, prior_id, email)
    end)
    |> Multi.run(:intent, fn _repo, %{prior_code: code} -> {:ok, stored_sign_up_intent(code)} end)
    |> commit_and_deliver_sign_up_code(email, context)
  end

  defp commit_and_deliver_sign_up_code(multi, email, context) do
    {nonce, secret, digest} = Crypto.magic_link_token()

    prior_codes_query =
      UserToken.Query.by_context("sign_up")
      |> UserToken.Query.by_sent_to(email)

    multi
    |> Multi.delete_all(:prior, prior_codes_query)
    |> Multi.insert(:token, fn %{intent: intent} ->
      UserToken.Changeset.sign_up(digest, email, @magic_link_attempts, intent)
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{token: token}} ->
        delivery =
          email
          |> Mailers.UserNotifier.deliver_sign_up_code(token.id, secret, context)
          |> delivery_outcome()

        {:ok, %{token_id: token.id, nonce: nonce, delivery: delivery}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The exact prior sign-up code, still addressed to this address and still
  # inside its window, under its row lock. Gone — consumed by completion or
  # replaced — is `{:error, :not_found}`, like any vanished code.
  defp lock_resendable_sign_up_code(repo, token_id, email) do
    code_query =
      UserToken.Query.by_id(token_id)
      |> UserToken.Query.by_context("sign_up")
      |> UserToken.Query.by_sent_to(email)
      |> UserToken.Query.lock_for_update()

    with {:ok, code} <- repo.fetch(code_query, UserToken.Query),
         true <- code_within_window?(code) do
      {:ok, code}
    else
      _ -> {:error, :not_found}
    end
  end

  # Advisory locks share one namespace per database, so the key is namespaced
  # and hashed by PostgreSQL itself, on the same lowercased address the unique
  # index compares.
  defp lock_sign_up_address(repo, email) do
    sql = "SELECT pg_advisory_xact_lock(hashtextextended($1 || lower($2), 0))"

    case Ecto.Adapters.SQL.query(repo, sql, ["emisar.auth.sign_up:", email]) do
      {:ok, _result} -> {:ok, :locked}
      {:error, reason} -> {:error, reason}
    end
  end

  defp delivery_outcome({:ok, %{suppressed: true}}), do: {:ok, :suppressed}
  defp delivery_outcome({:ok, _sent}), do: {:ok, :sent}
  defp delivery_outcome({:error, reason}), do: {:error, reason}

  # The unlocked read only decides which issuance to re-run; that issuance locks
  # and re-judges its own target. Attempts don't gate a resend — it mints a
  # fresh code.
  defp peek_resendable_code(token_id) do
    if Repo.valid_uuid?(token_id) do
      code =
        UserToken.Query.by_id(token_id)
        |> UserToken.Query.by_contexts(@email_code_contexts)
        |> Repo.peek()

      if code && code_within_window?(code), do: code
    end
  end

  # Freshness is judged per state, like the verify path: a verified code lives
  # by `verified_at` and its own window, a pending one by `inserted_at`.
  defp code_within_window?(%UserToken{} = code) do
    if code_verified?(code),
      do: verified_code_fresh?(code),
      else: fresh_since?(code.inserted_at, UserToken.Query.magic_link_validity_in_minutes() * 60)
  end

  defp stored_invitation(%UserToken{
         account_id: account_id,
         membership_id: membership_id,
         metadata: %{
           "invitation_token_digest" => token_digest,
           "invitation_display_name" => display_name
         }
       }) do
    %{
      account_id: account_id,
      membership_id: membership_id,
      token_digest: token_digest,
      display_name: display_name
    }
  end

  defp stored_invitation(%UserToken{}), do: nil

  defp stored_sign_up_intent(%UserToken{
         sent_to: email,
         metadata: %{"account_name" => account_name, "full_name" => full_name}
       }),
       do: %{email: email, account_name: account_name, full_name: full_name}

  @doc """
  Verifies a split code by reconstructing `hash(nonce <> secret)` and matching
  it against the locked token row. BOTH halves are required, so an intercepted
  email link or code can't sign in without the originating browser's nonce.
  Success marks that exact row verified, the short-lived factor the final
  transaction consumes; retrying the correct halves is idempotent and never
  extends that factor's age. A wrong half spends one of the
  #{@magic_link_attempts} attempts, and a spent-out or expired token reads as
  `{:error, :invalid_or_expired}`.

  Sign-in, invitation and sign-up codes all pass the same checks: addressed,
  fresh, both halves, attempts left. A Member's code (sign-in or invitation)
  locks that Member first and must still be addressed to its current address;
  it returns `{:ok, membership_id}`. A sign-up code has no Member yet and
  returns `{:ok, nil}`. Every failure is the same `{:error, :invalid_or_expired}`.
  """
  def verify_magic_link(token_id, secret, nonce, context \\ %RequestContext{})
      when is_binary(token_id) and is_binary(secret) and is_binary(nonce) do
    case peek_code_owner(token_id) do
      {:ok, owner} -> verify_code(owner, token_id, secret, nonce, context)
      :error -> record_magic_link_failure(token_id, :invalid_or_expired, context)
    end
  end

  defp verify_code(owner, token_id, secret, nonce, context) do
    Multi.new()
    |> put_code_owner_lock(owner)
    |> Multi.run(:token, &lock_presented_code(&1, &2, token_id))
    |> Multi.run(:outcome, fn repo, changes ->
      verify_code_outcome(repo, changes.token, code_addressed?(changes), secret, nonce)
    end)
    |> Multi.run(:verified_factor, &promote_verified_code/2)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{outcome: outcome, membership: membership}} when outcome in [:promote, :verified] ->
        {:ok, membership_id(membership)}

      {:ok, %{outcome: :invalid}} ->
        record_magic_link_failure(token_id, :invalid_or_expired, context)

      {:error, reason} ->
        record_magic_link_failure(token_id, reason, context)
    end
  end

  # The unlocked read only discovers which Member row to lock first. It grants
  # no authority: the transaction re-fetches and locks the exact code after
  # locking that Member.
  defp peek_code_owner(token_id) do
    code =
      if Repo.valid_uuid?(token_id) do
        UserToken.Query.by_id(token_id)
        |> UserToken.Query.by_contexts(@email_code_contexts)
        |> Repo.peek()
      end

    case code do
      %UserToken{context: "sign_up"} -> {:ok, :sign_up}
      %UserToken{account_id: account_id, membership_id: id} -> {:ok, {:member, account_id, id}}
      nil -> :error
    end
  end

  # A pending invitee and a suspended Member still own their codes; whether the
  # code may finish is decided when it is consumed.
  defp put_code_owner_lock(multi, {:member, account_id, membership_id}) do
    Multi.run(multi, :membership, fn repo, _changes ->
      Accounts.fetch_and_lock_sync_membership(repo, account_id, membership_id)
    end)
  end

  defp put_code_owner_lock(multi, :sign_up), do: Multi.put(multi, :membership, nil)

  defp lock_presented_code(repo, %{membership: membership}, token_id) do
    code_query =
      membership
      |> presented_code_query(token_id)
      |> UserToken.Query.lock_for_update()

    case repo.fetch(code_query, UserToken.Query) do
      {:ok, code} -> {:ok, code}
      {:error, :not_found} -> {:error, :invalid_or_expired}
    end
  end

  defp presented_code_query(nil, token_id) do
    UserToken.Query.by_id(token_id)
    |> UserToken.Query.by_context("sign_up")
  end

  defp presented_code_query(%Accounts.Membership{} = membership, token_id) do
    UserToken.Query.by_id(token_id)
    |> UserToken.Query.by_membership(membership.account_id, membership.id)
    |> UserToken.Query.by_contexts(@magic_link_contexts)
  end

  # A Member's code proves the address it was sent to only while that is still
  # the Member's address; a sign-up code must name the address it went to.
  defp code_addressed?(%{membership: nil, token: code}), do: is_binary(code.sent_to)

  defp code_addressed?(%{membership: %Accounts.Membership{email: email}, token: code}),
    do: is_binary(email) and code.sent_to == email

  defp verify_code_outcome(repo, %UserToken{} = code, addressed?, secret, nonce) do
    valid_digest? = Crypto.secure_compare(Crypto.magic_link_digest(nonce, secret), code.token)
    verified? = code_verified?(code)

    cond do
      not addressed? ->
        {:ok, :invalid}

      not verified? and not pending_code_fresh?(code) ->
        {:ok, :invalid}

      verified? and not verified_code_reverification_allowed?(code) ->
        {:ok, :invalid}

      valid_digest? and not verified? ->
        {:ok, :promote}

      valid_digest? ->
        {:ok, :verified}

      true ->
        {:ok, _code} = repo.update(UserToken.Changeset.decrement_attempts(code))
        {:ok, :invalid}
    end
  end

  defp promote_verified_code(repo, %{outcome: :promote, token: %UserToken{} = code}) do
    code
    |> verified_code_changeset(DateTime.utc_now())
    |> repo.update()
  end

  defp promote_verified_code(_repo, %{token: code}), do: {:ok, code}

  defp verified_code_changeset(%UserToken{context: "sign_up"} = code, verified_at),
    do: UserToken.Changeset.verified_sign_up(code, verified_at)

  defp verified_code_changeset(%UserToken{} = code, verified_at),
    do: UserToken.Changeset.verified_magic_link(code, verified_at)

  defp membership_id(nil), do: nil
  defp membership_id(%Accounts.Membership{id: id}), do: id

  # A sign-up code stays a `sign_up` row once verified; its `verified_at` marks it.
  defp code_verified?(%UserToken{context: "magic_link_verified"}), do: true
  defp code_verified?(%UserToken{context: "sign_up", metadata: %{"verified_at" => _}}), do: true
  defp code_verified?(%UserToken{}), do: false

  defp pending_code_fresh?(%UserToken{
         inserted_at: %DateTime{} = inserted_at,
         remaining_attempts: attempts
       }) do
    is_integer(attempts) and attempts > 0 and
      fresh_since?(inserted_at, UserToken.Query.magic_link_validity_in_minutes() * 60)
  end

  defp pending_code_fresh?(%UserToken{}), do: false

  defp verified_code_fresh?(%UserToken{metadata: %{"verified_at" => encoded}})
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

  defp verified_code_fresh?(%UserToken{}), do: false

  # Retrying the public emailed halves retains the same online-guess budget after
  # verification. Final completion already holds the server-issued handoff, so
  # it checks only factor age and is not denied by somebody exhausting public
  # retries against the same row.
  defp verified_code_reverification_allowed?(%UserToken{remaining_attempts: attempts} = code),
    do: is_integer(attempts) and attempts > 0 and verified_code_fresh?(code)

  defp fresh_since?(%DateTime{} = at, max_age_seconds) do
    DateTime.diff(DateTime.utc_now(), at, :second) in 0..max_age_seconds
  end

  # A code failed. `user.sign_in_failed` lands in the workspace of the Member
  # the token still names (a live code with a bad secret, or an expired or spent
  # one not yet deleted). A consumed or undecodable token, and a sign-up code,
  # name no Member — logged server-side instead. Every failure returns the SAME
  # `{:error, :invalid_or_expired}`, so the response can't be turned into an
  # enumeration oracle; a non-atom reason (a changeset) can't be JSON-encoded
  # into the payload, so it is recorded as the neutral reason.
  defp record_magic_link_failure(token_id, reason, context) do
    reason = if is_atom(reason), do: reason, else: :invalid_or_expired

    case peek_code_member(token_id) do
      %Accounts.Membership{} = membership ->
        event =
          Audit.Events.member_security_event(membership, "user.sign_in_failed", context, %{
            reason: reason,
            method: "magic_link"
          })

        {:ok, _event} = Audit.record(event)

      nil ->
        Logger.warning("magic-link sign-in failed for an unresolvable token")
    end

    {:error, :invalid_or_expired}
  end

  defp peek_code_member(token_id) do
    case peek_code_owner(token_id) do
      {:ok, {:member, account_id, membership_id}} ->
        Accounts.peek_sync_membership_by_id(account_id, membership_id)

      _sign_up_or_missing ->
        nil
    end
  end

  # -- Email-code sign-in completion ------------------------------------

  @mfa_sign_in_proof_salt "mfa sign-in proof"
  @mfa_sign_in_proof_max_age_seconds 120
  @member_mfa_reset_proof_salt "member mfa reset proof"
  @member_mfa_reset_proof_max_age_seconds 120
  @security_attempt_scopes SecurityAttemptWindow.scopes()

  @doc """
  Internal — factor one is done (`verify_magic_link/4` returned this
  `membership_id`) and the boundary asks the domain to finish the sign-in; the
  session token IS the credential being minted, so there's no Subject yet.
  `browser_id` is the browser's own random id from its session cookie; the
  session stores only its digest, so signing out of this browser ends every
  session it minted.

  Locks the workspace, then the Member, then the verified code, and holds them
  across the insert. The code must be this Member's, verified within its window
  and addressed to the Member's current address; it is consumed in the same
  transaction. A Member with TOTP still owes the second factor
  (`{:error, :mfa_required}`), judged on the locked row, so an enrollment that
  landed since the code was sent still forces it. A workspace that no longer
  accepts email sign-in refuses with `{:error, :sso_required}`. Provenance is
  fixed — `:magic_link` with no `mfa_verified_at` — so no caller can claim a
  factor it didn't verify.

  A code that carries an invitation accepts it in the same transaction: the
  pending Member must still hold the same invitation token and the invited
  address, and acceptance stamps that address verified. Where the workspace
  refuses email sign-in nothing is accepted, consumed or minted; the result is
  `{:ok, :sso_required, %{account: account, membership: pending_membership,
  proof: proof}}`, and `proof` continues the acceptance at one of the
  workspace's identity providers (`SSO.begin_invitation_sso_sign_in/4`).

  Returns `{:ok, %Accounts.Membership{account: account}, raw_token}`, or
  `{:error, :mfa_required | :invalid_or_expired | :invitation_invalid |
  :sso_required | {:account_disabled, account}}` — a disabled workspace never
  mints a session, and the boundary sends its Members to its own sign-in page.
  """
  def complete_magic_link_sign_in(
        membership_id,
        verified_token_id,
        browser_id,
        %RequestContext{} = context
      )
      when is_binary(browser_id),
      do: complete_code_sign_in(membership_id, verified_token_id, nil, browser_id, context)

  @doc """
  Internal — factor two is done: `proof` is the opaque term
  `verify_mfa_challenge/3` returned for the Member, and this mints the full
  session for it. The proof is re-checked against the LOCKED Member row before
  anything is written, so it is only good for the enrollment it was minted
  against: a disable, a re-enable, a secret rotation, or any other write to the
  Member since the challenge fails closed with `{:error, :mfa_proof_stale}`.
  Provenance is fixed to `:magic_link` with `mfa_verified_at` stamped now.
  Otherwise as `complete_magic_link_sign_in/4`.
  """
  def complete_magic_link_mfa_sign_in(
        proof,
        verified_token_id,
        browser_id,
        %RequestContext{} = context
      )
      when is_binary(browser_id) do
    case mfa_proof_membership_id(proof) do
      nil ->
        {:error, :mfa_proof_stale}

      membership_id ->
        complete_code_sign_in(membership_id, verified_token_id, proof, browser_id, context)
    end
  end

  # The unlocked read only chooses which transaction to build. Each one relocks
  # this exact code under its Member's lock and checks it still carries the
  # same intent, so a sign-in code never finishes as an acceptance or the
  # reverse.
  defp complete_code_sign_in(membership_id, verified_token_id, proof, browser_id, context) do
    case peek_verified_code(verified_token_id) do
      %UserToken{membership_id: ^membership_id, metadata: %{"invitation_token_digest" => _}} =
          code ->
        complete_invitation_sign_in(code, proof, browser_id, context)

      %UserToken{membership_id: ^membership_id} = code ->
        complete_member_sign_in(code, proof, browser_id, context)

      _missing_or_another_members ->
        {:error, :invalid_or_expired}
    end
  end

  defp peek_verified_code(token_id) do
    if Repo.valid_uuid?(token_id) do
      UserToken.Query.by_id(token_id)
      |> UserToken.Query.by_context("magic_link_verified")
      |> Repo.peek()
    end
  end

  defp complete_member_sign_in(%UserToken{} = code, proof, browser_id, context) do
    {token, digest} = Crypto.session_token()

    Multi.new()
    |> put_sign_in_account_lock(code.account_id)
    |> Multi.run(:membership, fn repo, %{account: account} ->
      fetch_and_lock_email_sign_in_member(repo, account, code.membership_id)
    end)
    |> Multi.run(:verified_factor, fn repo, %{membership: membership} ->
      lock_verified_code(repo, membership, code.id, nil)
    end)
    |> Multi.run(:mfa_state, fn _repo, %{membership: membership} ->
      with :ok <- ensure_mfa_state_current(membership, proof), do: {:ok, proof}
    end)
    |> put_magic_link_session(digest, browser_id, proof, context)
    |> Multi.delete(:consumed_magic_factor, fn %{verified_factor: factor} -> factor end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{account: account, membership: membership}} ->
        {:ok, %{membership | account: account}, token}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The acceptance commits with the session or not at all. Where the workspace
  # refuses email sign-in, the invitation stays pending and the verified code
  # stays unspent: the proof hands both to the SSO step, which accepts, binds
  # the identity and mints the session in one transaction.
  defp complete_invitation_sign_in(%UserToken{} = code, proof, browser_id, context) do
    {token, digest} = Crypto.session_token()
    invitation = stored_invitation(code)

    Multi.new()
    |> put_sign_in_account_lock(code.account_id)
    |> Multi.merge(fn %{account: account} ->
      if Accounts.email_sign_in_allowed?(account),
        do: put_invitation_email_sign_in(invitation, code, digest, browser_id, proof, context),
        else: put_invitation_sso_handoff(invitation, code, browser_id)
    end)
    |> Repo.commit_multi(after_commit: &Accounts.after_membership_activation_committed/1)
    |> case do
      {:ok, %{account: account, accepted: membership}} ->
        {:ok, %{membership | account: account}, token}

      {:ok, %{account: account, invitation: membership, invitation_sso_proof: sso_proof}} ->
        {:ok, :sso_required, %{account: account, membership: membership, proof: sso_proof}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_invitation_email_sign_in(invitation, code, digest, browser_id, proof, context) do
    Multi.new()
    |> Accounts.put_invitation_acceptance(invitation, code.sent_to)
    |> Multi.run(:verified_factor, fn repo, %{accepted: membership} ->
      lock_verified_code(repo, membership, code.id, invitation.token_digest)
    end)
    |> Multi.run(:mfa_state, fn _repo, %{accepted: membership} ->
      with :ok <- ensure_mfa_state_current(membership, proof), do: {:ok, proof}
    end)
    |> Multi.run(:membership, fn _repo, %{accepted: membership} -> {:ok, membership} end)
    |> put_magic_link_session(digest, browser_id, proof, context)
    |> Multi.delete(:consumed_magic_factor, fn %{verified_factor: factor} -> factor end)
  end

  # Judges the invitation and the verified code under their locks exactly as
  # acceptance would, and writes nothing. A merged Multi starts from an empty
  # accumulator, so the workspace (locked by the caller) comes from the
  # invitation, not from the outer changes.
  defp put_invitation_sso_handoff(invitation, code, browser_id) do
    Multi.new()
    |> Multi.run(:invitation, fn repo, _changes ->
      case Accounts.fetch_and_lock_pending_invitation(
             repo,
             invitation.account_id,
             invitation.membership_id,
             invitation.token_digest
           ) do
        {:ok, membership} -> {:ok, membership}
        {:error, :not_found} -> {:error, :invitation_invalid}
      end
    end)
    |> Multi.run(:verified_factor, fn repo, %{invitation: membership} ->
      lock_verified_code(repo, membership, code.id, invitation.token_digest)
    end)
    |> Multi.run(:invitation_sso_proof, fn _repo, %{verified_factor: factor} ->
      {:ok, invitation_sso_proof(invitation, factor, browser_id)}
    end)
  end

  # A disabled workspace never mints a session; the boundary sends its Members
  # to that workspace's own sign-in page, so it needs the account back.
  defp put_sign_in_account_lock(multi, account_id) do
    Multi.run(multi, :account, fn repo, _changes ->
      case Accounts.fetch_and_lock_account(account_id, repo: repo, include_deleted?: true) do
        {:ok, %Accounts.Account{deleted_at: nil, disabled_at: nil} = account} ->
          {:ok, account}

        {:ok, %Accounts.Account{deleted_at: nil} = account} ->
          {:error, {:account_disabled, account}}

        _deleted_or_missing ->
          {:error, :invalid_or_expired}
      end
    end)
  end

  # `invitation_digest` is the invitation the code must still carry: nil for a
  # plain sign-in code.
  defp lock_verified_code(repo, %Accounts.Membership{} = membership, token_id, invitation_digest) do
    code_query =
      UserToken.Query.by_id(token_id)
      |> UserToken.Query.by_membership(membership.account_id, membership.id)
      |> UserToken.Query.by_context("magic_link_verified")
      |> UserToken.Query.lock_for_update()

    with {:ok, code} <- repo.fetch(code_query, UserToken.Query),
         true <- code.sent_to == membership.email and verified_code_fresh?(code),
         true <- code.metadata["invitation_token_digest"] == invitation_digest do
      {:ok, code}
    else
      _ -> {:error, :invalid_or_expired}
    end
  end

  @invitation_sso_proof_salt "invitation sso proof"
  @invitation_sso_proof_max_age_seconds 10 * 60

  # The SSO step may only finish this exact acceptance: the workspace, the
  # pending Member, its invitation token, the verified code that proved the
  # invited inbox, and the browser that proved it. The name the invitee typed
  # and the address stay on the code (`peek_invitation_sso_acceptance/1`), so
  # the proof is a few ids in a session cookie already holding up to six
  # workspace sessions; the code is re-checked and consumed when the step
  # completes.
  defp invitation_sso_proof(invitation, %UserToken{} = code, browser_id) do
    Phoenix.Token.sign(
      mfa_proof_secret(),
      @invitation_sso_proof_salt,
      {:invitation_sso,
       %{
         account_id: invitation.account_id,
         membership_id: invitation.membership_id,
         token_digest: invitation.token_digest,
         code_id: code.id,
         browser_digest: Crypto.hash(browser_id)
       }}
    )
  end

  @doc """
  Internal — the SSO step of an invitation in a workspace that refuses email
  sign-in checks the proof `complete_magic_link_sign_in/4` returned, from the
  same browser, within the verified code's window. Returns `{:ok, proved}` —
  `%{account_id, membership_id, token_digest, code_id}` — or
  `{:error, :invitation_sso_invalid}`.
  """
  def verify_invitation_sso_proof(proof, browser_id)
      when is_binary(proof) and is_binary(browser_id) do
    case Phoenix.Token.verify(mfa_proof_secret(), @invitation_sso_proof_salt, proof,
           max_age: @invitation_sso_proof_max_age_seconds
         ) do
      {:ok, {:invitation_sso, %{browser_digest: browser_digest} = invitation}} ->
        if Crypto.secure_compare(browser_digest, Crypto.hash(browser_id)),
          do: {:ok, Map.delete(invitation, :browser_digest)},
          else: {:error, :invitation_sso_invalid}

      _invalid_or_expired ->
        {:error, :invitation_sso_invalid}
    end
  end

  def verify_invitation_sso_proof(_proof, _browser_id), do: {:error, :invitation_sso_invalid}

  @doc """
  Internal — what an invitation's SSO step accepts with: the name the invitee
  typed and the address its code proved, read from the verified code `proved`
  names (`verify_invitation_sso_proof/2`), which is still this invitation's and
  inside its window. An unlocked read: `put_invitation_sso_session/5` locks and
  re-checks that exact code in the accepting transaction. Returns
  `{:ok, invitation}` — `proved` plus `display_name` and `sent_to` — or
  `{:error, :invalid_or_expired}` once the code is spent, lapsed or another
  invitation's, as that transaction would find it.
  """
  def peek_invitation_sso_acceptance(
        %{
          account_id: account_id,
          membership_id: membership_id,
          token_digest: digest,
          code_id: code_id
        } =
          proved
      ) do
    UserToken.Query.by_id(code_id)
    |> UserToken.Query.by_membership(account_id, membership_id)
    |> UserToken.Query.by_context("magic_link_verified")
    |> Repo.peek()
    |> case do
      %UserToken{
        sent_to: sent_to,
        metadata: %{"invitation_token_digest" => ^digest, "invitation_display_name" => name}
      } = code ->
        if verified_code_fresh?(code),
          do: {:ok, Map.merge(proved, %{display_name: name, sent_to: sent_to})},
          else: {:error, :invalid_or_expired}

      _gone_or_another_invitation ->
        {:error, :invalid_or_expired}
    end
  end

  @doc """
  Internal — compose the end of an invitation's SSO step into
  `SSO.complete_invitation_sso_sign_in/5`'s transaction, after
  `Accounts.put_invitation_acceptance/3` (`:accepted`) and the identity binding
  (`:identity`, through the provider locked as `:locked_provider`). Locks and
  consumes the exact verified code the proof names — still the accepted
  Member's, still carrying the invitation, still addressed to its address and
  inside its window — then mints that Member's SSO session for the bound
  identity with `digest` and records the sign-in. No Subject: the transaction
  is the authentication.
  """
  def put_invitation_sso_session(
        %Multi{} = multi,
        %{code_id: code_id, token_digest: invitation_digest},
        digest,
        browser_id,
        %RequestContext{} = context
      )
      when is_binary(digest) and is_binary(browser_id) do
    multi
    |> Multi.run(:verified_factor, fn repo, %{accepted: membership} ->
      lock_verified_code(repo, membership, code_id, invitation_digest)
    end)
    |> Multi.run(:membership, fn _repo, %{accepted: membership} -> {:ok, membership} end)
    |> Multi.insert(:token, fn changes ->
      UserToken.Changeset.sso_session(
        changes.membership,
        digest,
        Crypto.hash(browser_id),
        request_metadata(context),
        changes.identity,
        changes.locked_provider
      )
    end)
    |> put_sign_in_records("sso", context)
    |> Multi.delete(:consumed_magic_factor, fn %{verified_factor: factor} -> factor end)
  end

  @doc """
  Internal — the sign-up code was verified (`verify_magic_link/4` returned
  `{:ok, nil}`) and the boundary finishes the sign-up; the session token IS the
  credential being minted, so there's no Subject yet. Locks and consumes the
  verified code FIRST — the one exception to the workspace-first lock order,
  because the workspace does not exist yet — then creates the workspace (its
  slug derived now), its owner Member with the proved address verified, the
  default policy, the sign-up audits and the owner's session in the same
  transaction. A double submit waits on the code's lock and then finds it
  consumed, so one sign-up makes one workspace. `browser_id` as in
  `complete_magic_link_sign_in/4`.

  Returns `{:ok, %Accounts.Membership{account: account}, raw_token}`, or
  `{:error, :invalid_or_expired | %Ecto.Changeset{}}`.
  """
  def complete_sign_up(verified_token_id, browser_id, %RequestContext{} = context)
      when is_binary(browser_id) do
    if Repo.valid_uuid?(verified_token_id) do
      {token, digest} = Crypto.session_token()

      Multi.new()
      |> Multi.run(:verified_factor, fn repo, _changes ->
        lock_verified_sign_up(repo, verified_token_id)
      end)
      |> Multi.delete(:consumed_sign_up_code, fn %{verified_factor: code} -> code end)
      |> Multi.merge(fn %{verified_factor: code} ->
        Accounts.put_sign_up_account(Multi.new(), stored_sign_up_intent(code))
      end)
      |> put_magic_link_session(digest, browser_id, nil, context)
      |> Repo.commit_multi()
      |> case do
        {:ok, %{account: account, membership: membership}} ->
          {:ok, %{membership | account: account}, token}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :invalid_or_expired}
    end
  end

  defp lock_verified_sign_up(repo, token_id) do
    code_query =
      UserToken.Query.by_id(token_id)
      |> UserToken.Query.by_context("sign_up")
      |> UserToken.Query.lock_for_update()

    with {:ok, code} <- repo.fetch(code_query, UserToken.Query),
         true <- code_verified?(code) and verified_code_fresh?(code) do
      {:ok, code}
    else
      _ -> {:error, :invalid_or_expired}
    end
  end

  # The one email-code session minter. `proof` is nil for a factor-one
  # completion and the verified MFA proof for factor two; the caller re-checks
  # it on the locked Member and this stamps the matching `mfa_verified_at`, so
  # the two can't disagree and no caller supplies either.
  defp put_magic_link_session(multi, digest, browser_id, proof, context) do
    mfa_verified_at = if proof, do: DateTime.utc_now()

    multi
    |> Multi.insert(:token, fn %{membership: membership} ->
      UserToken.Changeset.session(
        membership,
        digest,
        Crypto.hash(browser_id),
        request_metadata(context),
        mfa_verified_at
      )
    end)
    |> put_sign_in_records("magic_link", context)
  end

  # Factor one against an enrolled Member is unfinished business, not a session.
  defp ensure_mfa_state_current(%Accounts.Membership{mfa_enabled_at: %DateTime{}}, nil),
    do: {:error, :mfa_required}

  defp ensure_mfa_state_current(%Accounts.Membership{}, nil), do: :ok

  defp ensure_mfa_state_current(%Accounts.Membership{} = membership, proof) do
    with {:ok, payload} <- verify_mfa_proof(proof),
         true <- payload == mfa_proof_payload(membership) do
      :ok
    else
      _ -> {:error, :mfa_proof_stale}
    end
  end

  # -- SSO connection verification step-up -----------------------------

  @inbox_step_up_limit 5
  @inbox_step_up_window_ms 5 * 60_000
  @oidc_identity_step_up_attempts 5
  @oidc_identity_step_up_issue_limit 5
  @oidc_identity_step_up_issue_window_ms 15 * 60_000
  @oidc_identity_step_up_proof_salt "oidc identity step up proof"
  @oidc_identity_step_up_proof_max_age_seconds 5 * 60

  @doc """
  Begin the fresh local proof an administrator gives before verifying an SSO
  connection by signing in through it (`SSO.begin_identity_link/5`). A Member
  with an authenticator supplies a TOTP or recovery code; otherwise a
  single-use code goes to its verified address. The provider is bound into both
  the stored code and the short-lived proof confirmation returns. Self-service,
  gated by the Member's live session. Returns `{:ok, :mfa | :email}` or
  `{:error, :unauthorized | :email_unavailable | :rate_limited |
  :delivery_suppressed | term()}` — `:email_unavailable` when the Member has
  neither an authenticator nor a verified address, `:delivery_suppressed` when
  the address can't receive the code.
  """
  def begin_oidc_identity_step_up(provider_id, provider_name, %Subject{} = subject)
      when is_binary(provider_id) and is_binary(provider_name) do
    with {:ok, %UserToken{membership: membership}} <- fetch_current_session(subject) do
      cond do
        mfa_enabled?(membership) ->
          {:ok, :mfa}

        verified_address?(membership) ->
          case issue_oidc_identity_step_up_code(membership, provider_id, provider_name, subject) do
            {:ok, :sent} -> {:ok, :email}
            {:ok, :suppressed} -> {:error, :delivery_suppressed}
            {:error, reason} -> {:error, reason}
          end

        true ->
          {:error, :email_unavailable}
      end
    end
  end

  @doc """
  Issue a replacement code for an in-progress SSO connection verification
  step-up. Returns `{:ok, :sent}`, `{:ok, :suppressed}` (the address can't
  receive it), or `{:error, :unauthorized | :rate_limited | :factor_changed |
  :email_unavailable}` — `:factor_changed` once the Member enrolled an
  authenticator, which it must use instead.
  """
  def resend_oidc_identity_step_up_code(provider_id, provider_name, %Subject{} = subject)
      when is_binary(provider_id) and is_binary(provider_name) do
    with {:ok, %UserToken{membership: membership}} <- fetch_current_session(subject) do
      cond do
        mfa_enabled?(membership) ->
          {:error, :factor_changed}

        verified_address?(membership) ->
          issue_oidc_identity_step_up_code(membership, provider_id, provider_name, subject)

        true ->
          {:error, :email_unavailable}
      end
    end
  end

  defp issue_oidc_identity_step_up_code(membership, provider_id, provider_name, subject) do
    with :ok <-
           throttle_security_attempt(
             membership,
             :oidc_identity_step_up_issue,
             @oidc_identity_step_up_issue_limit,
             @oidc_identity_step_up_issue_window_ms,
             subject.context
           ) do
      {code, digest} = Crypto.credential_step_up_code()

      Multi.new()
      |> Multi.run(:membership, fn repo, _changes ->
        lock_inbox_step_up_member(repo, membership)
      end)
      |> Multi.delete_all(:prior, fn %{membership: locked} ->
        UserToken.Query.by_membership(locked.account_id, locked.id)
        |> UserToken.Query.by_context("oidc_identity_step_up")
      end)
      |> Multi.insert(:token, fn %{membership: locked} ->
        UserToken.Changeset.oidc_identity_step_up(
          locked,
          digest,
          provider_id,
          @oidc_identity_step_up_attempts
        )
      end)
      |> Multi.insert(:audit, fn %{membership: locked} ->
        Audit.Events.member_security_event(
          locked,
          "user.oidc_identity_step_up_requested",
          subject.context,
          %{provider_id: provider_id}
        )
      end)
      |> Repo.commit_multi()
      |> case do
        {:ok, %{membership: locked}} ->
          locked
          |> Mailers.UserNotifier.deliver_oidc_identity_step_up_code(
            code,
            provider_name,
            subject.context,
            subject.account
          )
          |> code_delivery_outcome()

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # An emailed step-up code goes to the Member's verified address, and only
  # while the Member has no authenticator to answer with instead.
  defp lock_inbox_step_up_member(repo, %Accounts.Membership{} = membership) do
    case Accounts.fetch_and_lock_active_membership(repo, membership.account_id, membership.id) do
      {:ok, %Accounts.Membership{mfa_enabled_at: %DateTime{}}} ->
        {:error, :factor_changed}

      {:ok, locked} ->
        if verified_address?(locked), do: {:ok, locked}, else: {:error, :email_unavailable}

      {:error, :not_found} ->
        {:error, :unauthorized}
    end
  end

  defp code_delivery_outcome({:ok, %{suppressed: true}}), do: {:ok, :suppressed}
  defp code_delivery_outcome({:ok, _sent}), do: {:ok, :sent}
  defp code_delivery_outcome({:error, reason}), do: {:error, reason}

  @doc """
  Confirm the fresh local proof for verifying `provider_id` and return an
  opaque, provider-bound proof for `SSO.begin_identity_link/5`: the Member's
  current TOTP or recovery code when it has an authenticator, otherwise the
  emailed code. Self-service, gated by the Member's live session. Returns
  `{:ok, proof}` or `{:error, :unauthorized | :invalid | :replay |
  :rate_limited}`.
  """
  def confirm_oidc_identity_step_up(provider_id, code, %Subject{} = subject)
      when is_binary(provider_id) and is_binary(code) do
    code = String.trim(code)

    with {:ok, %UserToken{membership: membership}} <- fetch_current_session(subject),
         {:ok, verified} <-
           verify_oidc_identity_step_up_factor(membership, provider_id, code, subject) do
      {:ok, oidc_identity_step_up_proof(verified, provider_id)}
    end
  end

  defp verify_oidc_identity_step_up_factor(
         %Accounts.Membership{mfa_enabled_at: %DateTime{}} = membership,
         _provider_id,
         code,
         subject
       ),
       do: verify_current_mfa_factor(membership, code, subject.context)

  defp verify_oidc_identity_step_up_factor(membership, provider_id, code, subject) do
    with :ok <-
           throttle_security_attempt(
             membership,
             :inbox_step_up,
             @inbox_step_up_limit,
             @inbox_step_up_window_ms,
             subject.context
           ) do
      case consume_oidc_identity_step_up_code(membership, provider_id, code) do
        {:ok, verified} ->
          {:ok, verified}

        # A wrong or expired emailed code leaves an audit trail (the TOTP factor
        # path records its miss too) so grinding a hijacked session is visible.
        {:error, reason} ->
          record_member_security_event(
            membership,
            "user.oidc_identity_step_up_failed",
            subject.context,
            %{reason: to_string(reason)}
          )

          {:error, reason}
      end
    end
  end

  defp consume_oidc_identity_step_up_code(membership, provider_id, code) do
    Multi.new()
    |> Multi.run(:membership, fn repo, _changes ->
      Accounts.fetch_and_lock_active_membership(repo, membership.account_id, membership.id)
    end)
    |> Multi.run(:outcome, fn repo, %{membership: locked} ->
      token =
        UserToken.Query.by_membership(locked.account_id, locked.id)
        |> UserToken.Query.by_context("oidc_identity_step_up")
        |> UserToken.Query.not_expired("oidc_identity_step_up")
        |> UserToken.Query.with_attempts_remaining()
        |> UserToken.Query.lock_for_update()
        |> repo.one()

      verify_oidc_identity_step_up_code(repo, token, locked, provider_id, code)
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{outcome: {:ok, verified}}} -> {:ok, verified}
      {:ok, %{outcome: {:error, reason}}} -> {:error, reason}
      {:error, :not_found} -> {:error, :invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_oidc_identity_step_up_code(repo, token, membership, provider_id, code) do
    expected_metadata = %{
      "provider_id" => provider_id,
      "membership_updated_at" => DateTime.to_iso8601(membership.updated_at)
    }

    cond do
      is_nil(token) or not is_nil(membership.mfa_enabled_at) or
          not verified_address?(membership) ->
        {:ok, {:error, :invalid}}

      token.sent_to != membership.email or token.metadata != expected_metadata ->
        {:ok, {:error, :invalid}}

      Crypto.secure_compare(Crypto.hash(code), token.token) ->
        {:ok, _deleted} = repo.delete(token)
        {:ok, {:ok, membership}}

      true ->
        {:ok, _updated} = repo.update(UserToken.Changeset.decrement_attempts(token))
        {:ok, {:error, :invalid}}
    end
  end

  @doc """
  Internal — recheck a connection-verification proof against a freshly read
  Member row: the same Member, address, enrollment and row version it was
  confirmed for, within five minutes, for this provider.
  """
  def verify_oidc_identity_step_up_proof(
        proof,
        provider_id,
        %Accounts.Membership{} = membership
      )
      when is_binary(proof) and is_binary(provider_id) do
    case Phoenix.Token.verify(mfa_proof_secret(), @oidc_identity_step_up_proof_salt, proof,
           max_age: @oidc_identity_step_up_proof_max_age_seconds
         ) do
      {:ok, payload} ->
        if payload == oidc_identity_step_up_proof_payload(membership, provider_id),
          do: :ok,
          else: {:error, :identity_step_up_stale}

      _other ->
        {:error, :identity_step_up_stale}
    end
  end

  def verify_oidc_identity_step_up_proof(_proof, _provider_id, %Accounts.Membership{}),
    do: {:error, :identity_step_up_stale}

  @doc """
  Internal — inside `SSO.complete_identity_link/4`'s transaction, after the
  Member's lock: recheck the proof against the locked Member and lock the exact
  live session of that Member it is bound to.
  """
  def ensure_oidc_identity_step_up_current(
        repo,
        proof,
        session_token_digest,
        provider_id,
        %Accounts.Membership{} = membership
      )
      when is_binary(session_token_digest) do
    session_query =
      UserToken.Query.authorized()
      |> UserToken.Query.by_token_digest(session_token_digest)
      |> UserToken.Query.by_membership(membership.account_id, membership.id)
      |> UserToken.Query.lock_tokens_for_update()

    with :ok <- verify_oidc_identity_step_up_proof(proof, provider_id, membership),
         {:ok, %UserToken{}} <- repo.fetch(session_query, UserToken.Query) do
      :ok
    else
      _other -> {:error, :identity_step_up_stale}
    end
  end

  defp oidc_identity_step_up_proof(membership, provider_id) do
    Phoenix.Token.sign(
      mfa_proof_secret(),
      @oidc_identity_step_up_proof_salt,
      oidc_identity_step_up_proof_payload(membership, provider_id)
    )
  end

  defp oidc_identity_step_up_proof_payload(%Accounts.Membership{} = membership, provider_id) do
    {:oidc_identity_step_up, membership.id, membership.email, membership.mfa_enabled_at,
     membership.updated_at, provider_id}
  end

  # -- MFA scaffold -----------------------------------------------------

  @doc """
  The caller's own second-factor state for display: is TOTP on, how many
  recovery codes are left, and how this Member can prove its own credential
  before adding an authenticator — `:email` (a code to its verified address),
  `:sso` (a fresh sign-in at the IdP behind this SSO session,
  `SSO.begin_mfa_enrollment_reauthentication/3`) or `:unavailable`. Rechecks the
  live session and the current Member, never surfacing the TOTP secret or
  recovery-code digests. Returns `{:ok, %MfaFacts{}}` or
  `{:error, :unauthorized}` once the session no longer authenticates.
  """
  def mfa_facts(%Subject{} = subject) do
    with {:ok, %UserToken{membership: membership} = session} <- fetch_current_session(subject) do
      {:ok,
       %MfaFacts{
         enabled?: mfa_enabled?(membership),
         recovery_codes_remaining: recovery_codes_remaining(membership),
         enrollment_proof: mfa_enrollment_proof_method(session)
       }}
    end
  end

  defp mfa_enabled?(%Accounts.Membership{mfa_enabled_at: %DateTime{}}), do: true
  defp mfa_enabled?(%Accounts.Membership{}), do: false

  # Unused digests — a consumed recovery code is removed from the row.
  defp recovery_codes_remaining(%Accounts.Membership{mfa_recovery_codes: codes})
       when is_list(codes),
       do: length(codes)

  defp recovery_codes_remaining(%Accounts.Membership{}), do: 0

  # Session age never counts: a verified address takes an emailed code, and an
  # SSO session of a workspace that still has SSO takes a fresh IdP sign-in.
  defp mfa_enrollment_proof_method(%UserToken{membership: membership} = session) do
    cond do
      verified_address?(membership) -> :email
      session.auth_method == :sso and Billing.sso_available?(membership.account) -> :sso
      true -> :unavailable
    end
  end

  @mfa_enrollment_code_attempts 5
  @mfa_enrollment_issue_limit 5
  @mfa_enrollment_issue_window_ms 15 * 60_000
  @mfa_enrollment_pending_max_age_seconds 60
  @mfa_enrollment_proof_salt "mfa enrollment proof"
  @mfa_enrollment_proof_max_age_seconds 5 * 60

  @doc """
  Emails a current-inbox proof code to the Member's verified address before it
  may enroll a new MFA factor. The dedicated token is single-use, expires after
  15 minutes, and has five token-local guesses. Delivery also shares a durable
  five-per-15-minute budget per Member across Portal nodes and reloads.
  Self-service, gated by the Member's live session. Returns `{:ok, :sent}`,
  `{:ok, :suppressed}` when the address cannot receive Emisar mail, or
  `{:error, :unauthorized | :email_unavailable | :mfa_already_enabled |
  :rate_limited | :issuance_in_progress | term()}` — `:email_unavailable` for a
  Member without a verified address, which proves itself through SSO instead.
  """
  def issue_mfa_enrollment_code(%Subject{} = subject) do
    with {:ok, %UserToken{membership: membership}} <- fetch_current_session(subject),
         :ok <- ensure_mfa_enrollment_open(membership),
         :ok <-
           throttle_security_attempt(
             membership,
             :mfa_enrollment_issue,
             @mfa_enrollment_issue_limit,
             @mfa_enrollment_issue_window_ms,
             subject.context
           ) do
      {code, digest} = Crypto.credential_step_up_code()

      Multi.new()
      |> Multi.run(:membership, fn repo, _changes ->
        lock_mfa_enrollment_member(repo, membership)
      end)
      |> Multi.run(:token, fn repo, %{membership: locked} ->
        pending_query =
          UserToken.Query.by_membership(locked.account_id, locked.id)
          |> UserToken.Query.by_context("mfa_enrollment_pending")
          |> UserToken.Query.lock_for_update()

        if Enum.any?(repo.all(pending_query), &recent_mfa_enrollment_pending?/1) do
          {:error, :issuance_in_progress}
        else
          # A process can die after recording a request but before finalizing its
          # delivery. Reclaim that non-verifiable pending row after the mailer's
          # maximum useful wait while the Member lock excludes a competing issue.
          {_count, nil} =
            UserToken.Query.by_membership(locked.account_id, locked.id)
            |> UserToken.Query.by_context("mfa_enrollment_pending")
            |> repo.delete_all()

          locked
          |> UserToken.Changeset.pending_mfa_enrollment(digest, @mfa_enrollment_code_attempts)
          |> repo.insert()
        end
      end)
      |> Multi.insert(:audit, fn %{membership: locked} ->
        Audit.Events.member_security_event(
          locked,
          "user.mfa_enrollment_requested",
          subject.context
        )
      end)
      |> Repo.commit_multi()
      |> case do
        {:ok, %{membership: locked, token: token}} ->
          delivery =
            locked
            |> Mailers.UserNotifier.deliver_mfa_enrollment_code(
              code,
              subject.context,
              subject.account
            )
            |> code_delivery_outcome()

          finalize_mfa_enrollment_delivery(token, locked, delivery)

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
         %Accounts.Membership{} = membership,
         {:ok, :sent} = delivery
       ) do
    Multi.new()
    |> Multi.run(:membership, fn repo, _changes ->
      Accounts.fetch_and_lock_active_membership(repo, membership.account_id, membership.id)
    end)
    |> Multi.run(:pending, fn repo, _changes ->
      loaded_query =
        UserToken.Query.by_id(pending.id)
        |> UserToken.Query.by_membership(membership.account_id, membership.id)
        |> UserToken.Query.by_context("mfa_enrollment_pending")
        |> UserToken.Query.lock_for_update()

      case repo.fetch(loaded_query, UserToken.Query) do
        {:ok, loaded} -> {:ok, loaded}
        {:error, :not_found} -> {:error, :issuance_expired}
      end
    end)
    |> Multi.delete_all(:prior, fn _changes ->
      UserToken.Query.by_membership(membership.account_id, membership.id)
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

  defp finalize_mfa_enrollment_delivery(%UserToken{} = pending, membership, delivery) do
    UserToken.Query.by_id(pending.id)
    |> UserToken.Query.by_membership(membership.account_id, membership.id)
    |> UserToken.Query.by_context("mfa_enrollment_pending")
    |> Repo.delete_all()

    delivery
  end

  @doc """
  Consumes the emailed MFA-enrollment code and returns a short-lived opaque
  proof bound to the Member's address and row version. Verification spends the
  Member's shared current-inbox attempt budget, so replacing this token cannot
  reset the guessing window. `enable_mfa/5` rechecks the proof against the
  locked current Member before writing the new factor. Returns `{:ok, proof}`
  or `{:error, :unauthorized | :email_unavailable | :mfa_already_enabled |
  :rate_limited | :invalid}`.
  """
  def verify_mfa_enrollment_code(code, %Subject{} = subject) when is_binary(code) do
    with {:ok, %UserToken{membership: membership}} <- fetch_current_session(subject),
         :ok <- ensure_mfa_enrollment_open(membership),
         :ok <-
           throttle_security_attempt(
             membership,
             :inbox_step_up,
             @inbox_step_up_limit,
             @inbox_step_up_window_ms,
             subject.context
           ) do
      case consume_mfa_enrollment_code(code, membership) do
        {:ok, verified} ->
          {:ok, mfa_enrollment_proof(:email, email_enrollment_payload(verified))}

        # A wrong or expired emailed code leaves an audit trail so grinding a
        # hijacked session toward MFA enrollment is visible.
        {:error, reason} ->
          record_member_security_event(
            membership,
            "user.mfa_enrollment_failed",
            subject.context,
            %{reason: to_string(reason)}
          )

          {:error, reason}
      end
    end
  end

  defp ensure_mfa_not_enabled(%Accounts.Membership{mfa_enabled_at: nil}), do: :ok
  defp ensure_mfa_not_enabled(%Accounts.Membership{}), do: {:error, :mfa_already_enabled}

  # An emailed enrollment code proves the inbox only at an address joining
  # proved; a directory or IdP address never qualifies.
  defp ensure_mfa_enrollment_open(%Accounts.Membership{} = membership) do
    with :ok <- ensure_mfa_not_enabled(membership) do
      if verified_address?(membership), do: :ok, else: {:error, :email_unavailable}
    end
  end

  defp lock_mfa_enrollment_member(repo, %Accounts.Membership{} = membership) do
    with {:ok, locked} <-
           Accounts.fetch_and_lock_active_membership(repo, membership.account_id, membership.id),
         :ok <- ensure_mfa_enrollment_open(locked) do
      {:ok, locked}
    end
  end

  defp consume_mfa_enrollment_code(code, membership) do
    Multi.new()
    |> Multi.run(:membership, fn repo, _changes ->
      lock_mfa_enrollment_member(repo, membership)
    end)
    |> Multi.run(:token, fn repo, %{membership: locked} ->
      loaded_token_query =
        UserToken.Query.by_membership(locked.account_id, locked.id)
        |> UserToken.Query.by_context("mfa_enrollment")
        |> UserToken.Query.not_expired("mfa_enrollment")
        |> UserToken.Query.with_attempts_remaining()
        |> UserToken.Query.lock_for_update()

      case repo.fetch(loaded_token_query, UserToken.Query) do
        {:ok, loaded_token} -> {:ok, loaded_token}
        {:error, :not_found} -> {:error, :invalid}
      end
    end)
    |> Multi.run(:outcome, fn repo, %{membership: locked, token: token} ->
      cond do
        not mfa_enrollment_token_current?(token, locked) ->
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
      {:ok, %{membership: locked, outcome: {:ok, _token}}} -> {:ok, locked}
      {:ok, %{outcome: {:error, :invalid}}} -> {:error, :invalid}
      {:error, :not_found} -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mfa_enrollment_token_current?(%UserToken{} = token, %Accounts.Membership{} = membership) do
    token.sent_to == membership.email and
      token.metadata["membership_updated_at"] == DateTime.to_iso8601(membership.updated_at)
  end

  @doc """
  The enrollment proof a fresh SSO sign-in gives. `reauthentication` is what
  `SSO.complete_mfa_enrollment_reauthentication/4` returned for this session:
  the provider, the identity and its subject, the namespace, the IdP
  `auth_time` and the digest of the session the ceremony began from.
  `presented_digest` is this browser's session digest; both must name the
  Member's live SSO session on that exact identity. Rechecked under the
  Member's lock, the short-lived proof binds all of it to the Member's current
  row version, and `enable_mfa/5` rechecks the identity and the provider under
  their locks. Returns `{:ok, proof}` or `{:error, :unauthorized |
  :mfa_already_enabled | :mfa_enrollment_proof_stale}`.
  """
  def issue_mfa_enrollment_proof_for_sso(
        %{
          provider_id: provider_id,
          identity_id: identity_id,
          provider_identifier: provider_identifier,
          namespace: {issuer, _client_id, _identifier_claim} = namespace,
          auth_time: auth_time,
          session_digest: session_digest
        },
        presented_digest,
        %Subject{} = subject
      )
      when is_binary(provider_id) and is_binary(identity_id) and
             is_binary(provider_identifier) and is_binary(issuer) and is_integer(auth_time) and
             is_binary(session_digest) and is_binary(presented_digest) do
    with {:ok, %UserToken{} = session} <- fetch_current_session(subject),
         true <- Crypto.secure_compare(session.token, presented_digest),
         true <- Crypto.secure_compare(session_digest, presented_digest),
         true <- session.auth_method == :sso and session.user_identity_id == identity_id,
         {:ok, locked} <- lock_sso_enrollment_member(session.membership) do
      {:ok,
       mfa_enrollment_proof(:sso, %{
         membership_id: locked.id,
         updated_at: locked.updated_at,
         provider_id: provider_id,
         identity_id: identity_id,
         provider_identifier: provider_identifier,
         namespace: namespace,
         auth_time: auth_time,
         session_digest: session_digest
       })}
    else
      {:error, reason} when reason in [:unauthorized, :mfa_already_enabled] -> {:error, reason}
      _other -> {:error, :mfa_enrollment_proof_stale}
    end
  end

  def issue_mfa_enrollment_proof_for_sso(_reauthentication, _presented_digest, %Subject{}),
    do: {:error, :mfa_enrollment_proof_stale}

  defp lock_sso_enrollment_member(%Accounts.Membership{} = membership) do
    Multi.new()
    |> Multi.run(:membership, fn repo, _changes ->
      with {:ok, locked} <-
             Accounts.fetch_and_lock_active_membership(
               repo,
               membership.account_id,
               membership.id
             ),
           :ok <- ensure_mfa_not_enabled(locked) do
        {:ok, locked}
      end
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{membership: locked}} -> {:ok, locked}
      {:error, :not_found} -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Generates a fresh TOTP secret for the Member. Caller is responsible for
  displaying the QR code; nothing is persisted until `enable_mfa/5` confirms
  both the enrollment proof and the authenticator code.
  """
  def generate_mfa_secret, do: Crypto.totp_secret()

  # 10 recovery codes is the de facto standard (matches GitHub, Google
  # Workspace, etc). Returned in plaintext exactly once at enable-time;
  # we only persist the digests. Each code's shape (length, encoding,
  # digest) is `Crypto.mfa_recovery_code/0`'s concern.
  @recovery_code_count 10

  @doc """
  Enable TOTP for the caller's Member after a fresh proof of its own credential:
  the emailed-code proof from `verify_mfa_enrollment_code/2`, or the SSO proof
  from `issue_mfa_enrollment_proof_for_sso/3`. Session age never counts.
  Verifies the OTP against the proposed secret, then in one transaction locks
  the workspace; for an SSO proof, its entitlement, the provider (still enabled
  at the namespace the IdP sign-in proved) and the identity (still this
  Member's, same subject), with the sign-in still recent; then the Member,
  which must still be unenrolled at the row version the proof was minted for
  (and for an emailed proof still hold that verified address); then this exact
  live session, which for an SSO proof must be the very SSO session the
  ceremony began from on that identity. Only then are the factor, its
  `user.mfa_enabled` audit row and this session's local proof stamp written,
  so recovery codes are never emitted for an enrollment whose browser cannot
  continue.

  `presented_digest` is the stored token digest of the browser session
  completing enrollment (the raw cookie never reaches this layer). Returns
  `{:ok, %Accounts.Membership{}, recovery_codes}` — show the codes once and
  never again — or `{:error, :invalid_otp | :mfa_enrollment_proof_stale |
  :mfa_already_enabled | :session_not_found | term()}`.
  """
  def enable_mfa(
        secret,
        otp,
        proof,
        presented_digest,
        %Subject{
          actor: %Accounts.Membership{id: membership_id},
          account: %Accounts.Account{id: account_id}
        } = subject
      )
      when is_binary(secret) and is_binary(otp) and is_binary(proof) and
             is_binary(presented_digest) do
    with {:ok, enrollment} <- verify_mfa_enrollment_proof(proof, membership_id),
         true <- Crypto.valid_totp?(secret, otp) do
      {plain_codes, digests} = generate_recovery_codes()

      Multi.new()
      |> Multi.run(:account, fn repo, _changes ->
        Accounts.fetch_and_lock_account(account_id, repo: repo)
      end)
      |> put_mfa_enrollment_reauthentication(enrollment, account_id, membership_id)
      |> Multi.run(:membership, fn repo, _changes ->
        lock_enrolling_member(repo, account_id, membership_id, enrollment)
      end)
      |> Multi.run(:session, fn repo, _changes ->
        lock_enrolling_session(repo, presented_digest, subject, enrollment)
      end)
      |> Multi.run(:enabled_at, fn _repo, _changes -> {:ok, DateTime.utc_now()} end)
      |> Multi.merge(fn %{membership: locked, session: session, enabled_at: enabled_at} ->
        Multi.new()
        |> Accounts.put_member_mfa_enrollment(
          locked,
          secret,
          enabled_at,
          digests,
          subject.context
        )
        |> Multi.update(:mfa_session, UserToken.Changeset.local_mfa_verified(session, enabled_at))
      end)
      |> Repo.commit_multi()
      |> case do
        {:ok, %{mfa_enrollment: enrolled}} -> {:ok, enrolled, plain_codes}
        {:error, reason} -> {:error, reason}
      end
    else
      false -> {:error, :invalid_otp}
      {:error, reason} -> {:error, reason}
    end
  end

  def enable_mfa(_secret, _otp, _proof, _presented_digest, %Subject{}),
    do: {:error, :mfa_enrollment_proof_stale}

  defp mfa_enrollment_proof(method, payload) when method in [:email, :sso] do
    Phoenix.Token.sign(
      mfa_proof_secret(),
      @mfa_enrollment_proof_salt,
      {:mfa_enrollment, method, payload}
    )
  end

  defp email_enrollment_payload(%Accounts.Membership{} = membership),
    do: %{
      membership_id: membership.id,
      email: membership.email,
      updated_at: membership.updated_at
    }

  defp verify_mfa_enrollment_proof(proof, membership_id) do
    case Phoenix.Token.verify(mfa_proof_secret(), @mfa_enrollment_proof_salt, proof,
           max_age: @mfa_enrollment_proof_max_age_seconds
         ) do
      {:ok,
       {:mfa_enrollment, :email,
        %{membership_id: ^membership_id, email: email, updated_at: %DateTime{}} = payload}}
      when is_binary(email) ->
        {:ok, {:email, payload}}

      {:ok,
       {:mfa_enrollment, :sso,
        %{
          membership_id: ^membership_id,
          updated_at: %DateTime{},
          provider_id: provider_id,
          identity_id: identity_id,
          provider_identifier: provider_identifier,
          namespace: {issuer, _client_id, _identifier_claim},
          auth_time: auth_time,
          session_digest: session_digest
        } = payload}}
      when is_binary(provider_id) and is_binary(identity_id) and
             is_binary(provider_identifier) and is_binary(issuer) and is_integer(auth_time) and
             is_binary(session_digest) ->
        {:ok, {:sso, payload}}

      _other ->
        {:error, :mfa_enrollment_proof_stale}
    end
  end

  # Revision 8: an SSO proof is only as good as the route it proved, rechecked
  # under the entitlement, provider and identity locks, before the Member's.
  defp put_mfa_enrollment_reauthentication(multi, {:email, _payload}, _account_id, _id),
    do: multi

  defp put_mfa_enrollment_reauthentication(multi, {:sso, payload}, account_id, membership_id) do
    Multi.run(multi, :reauthentication, fn repo, _changes ->
      SSO.ensure_mfa_enrollment_reauthentication_current(
        repo,
        payload,
        membership_id,
        account_id
      )
    end)
  end

  defp lock_enrolling_member(repo, account_id, membership_id, enrollment) do
    with {:ok, locked} <-
           Accounts.fetch_and_lock_active_membership(repo, account_id, membership_id),
         :ok <- ensure_mfa_not_enabled(locked),
         true <- mfa_enrollment_current?(locked, enrollment) do
      {:ok, locked}
    else
      {:error, :mfa_already_enabled} -> {:error, :mfa_already_enabled}
      _other -> {:error, :mfa_enrollment_proof_stale}
    end
  end

  defp mfa_enrollment_current?(%Accounts.Membership{} = locked, {:email, payload}) do
    verified_address?(locked) and locked.email == payload.email and
      locked.updated_at == payload.updated_at
  end

  defp mfa_enrollment_current?(%Accounts.Membership{} = locked, {:sso, payload}),
    do: locked.updated_at == payload.updated_at

  defp lock_enrolling_session(repo, presented_digest, subject, enrollment) do
    with {:ok, session} <- lock_subject_session(repo, presented_digest, subject) do
      if enrollment_session?(session, enrollment),
        do: {:ok, session},
        else: {:error, :mfa_enrollment_proof_stale}
    end
  end

  defp enrollment_session?(%UserToken{}, {:email, _payload}), do: true

  defp enrollment_session?(
         %UserToken{auth_method: :sso} = session,
         {:sso, %{namespace: {issuer, _client_id, _claim}} = payload}
       ) do
    Crypto.secure_compare(session.token, payload.session_digest) and
      session.user_identity_id == payload.identity_id and
      session.sso_provider_identifier == payload.provider_identifier and
      session.sso_issuer == issuer
  end

  defp enrollment_session?(%UserToken{}, {:sso, _payload}), do: false

  # The exact live session this Member Subject acts through, presented by this
  # browser, locked for a credential write.
  defp lock_subject_session(
         repo,
         presented_digest,
         %Subject{
           account: %Accounts.Account{id: account_id},
           membership_id: membership_id,
           session_token_id: session_id
         }
       )
       when is_binary(presented_digest) do
    if Repo.valid_uuid?(session_id) and Repo.valid_uuid?(membership_id) do
      UserToken.Query.authorized()
      |> UserToken.Query.by_token_digest(presented_digest)
      |> UserToken.Query.by_id(session_id)
      |> UserToken.Query.by_membership(account_id, membership_id)
      |> UserToken.Query.lock_tokens_for_update()
      |> repo.fetch(UserToken.Query)
      |> case do
        {:ok, %UserToken{} = session} -> {:ok, session}
        {:error, :not_found} -> {:error, :session_not_found}
      end
    else
      {:error, :session_not_found}
    end
  end

  defp lock_subject_session(_repo, _presented_digest, %Subject{}),
    do: {:error, :session_not_found}

  @doc """
  Disable TOTP for the caller's Member after verifying a current TOTP or
  recovery code. Both verification paths validate against the current row under
  a lock, and the factor's removal and its `user.mfa_disabled` audit row commit
  together.

  Sessions survive: a session's local MFA proof is bound to the enrollment it
  proved (`Subject.for_session/2`), so tearing the factor down already strips
  every live session of the Member of its second-factor claim without signing
  anyone out.

  Their live SOCKETS do not survive, because a mounted socket decided its gates
  once and holds a `%Subject{}` built from the old enrollment. Dropping the
  Member's sockets after the write makes each one reconnect, remount, and
  re-decide against the rebuilt Subject — the cookie is still valid, so nobody
  is signed out.

  Returns `{:ok, %Accounts.Membership{}}`, `{:error, :invalid_code | :replay}`
  when the factor is rejected, `{:error, :rate_limited}` once the Member's
  shared MFA attempt window is exhausted, or `{:error, :unauthorized |
  :mfa_not_enabled | term()}`.
  """
  def disable_mfa(code, %Subject{} = subject) when is_binary(code) do
    code = String.trim(code)

    with {:ok, %UserToken{membership: membership}} <- fetch_current_session(subject),
         {:ok, verified} <- verify_current_mfa_factor(membership, code, subject.context),
         {:ok, disabled} <-
           Accounts.disable_member_mfa(verified,
             audit: &Audit.Events.member_security_event(&1, "user.mfa_disabled", subject.context)
           ) do
      :ok = broadcast_disconnect_for_membership(disabled)
      {:ok, disabled}
    else
      {:error, :invalid} -> {:error, :invalid_code}
      {:error, reason} -> {:error, reason}
    end
  end

  def disable_mfa(_code, %Subject{}), do: {:error, :invalid_code}

  defp record_mfa_mutation_failure(membership, factor, reason, context) do
    record_member_security_event(membership, "user.mfa_failed", context, %{
      reason: if(reason == :replay, do: "replay", else: regeneration_failure_reason(factor))
    })

    {:error, if(reason == :replay, do: :replay, else: :invalid_code)}
  end

  defp verify_current_mfa_factor(membership, code, context) do
    if Regex.match?(~r/\A\d{6}\z/, code) do
      verify_mfa(membership, code, context)
    else
      consume_mfa_recovery_code(membership, code, context)
    end
  end

  @doc """
  Regenerate the Member's recovery code set after proving a current TOTP or
  recovery code. Invalidates the prior codes and returns the new plaintext set
  once. Verification spends the Member's shared MFA attempt budget; the final
  replacement also requires MFA to remain enabled on the locked current row.
  Returns `{:ok, %Accounts.Membership{}, recovery_codes}` or `{:error,
  :invalid_code | :replay | :rate_limited | :mfa_not_enabled | :unauthorized}`.
  """
  def regenerate_mfa_recovery_codes(code, %Subject{} = subject) when is_binary(code) do
    code = String.trim(code)

    with {:ok, %UserToken{membership: membership}} <- fetch_current_session(subject),
         :ok <- ensure_mfa_enabled(membership),
         :ok <- throttle_mfa_challenge(membership, subject.context) do
      factor = current_mfa_factor(code)
      {plain_codes, digests} = generate_recovery_codes()

      membership
      |> Accounts.regenerate_member_mfa_recovery_codes(factor, digests,
        audit:
          &Audit.Events.member_security_event(
            &1,
            "user.mfa_recovery_codes_regenerated",
            subject.context
          )
      )
      |> case do
        {:ok, updated} ->
          {:ok, updated, plain_codes}

        {:error, reason} when reason in [:invalid, :replay] ->
          record_mfa_mutation_failure(membership, factor, reason, subject.context)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def regenerate_mfa_recovery_codes(_code, %Subject{}), do: {:error, :invalid_code}

  defp ensure_mfa_enabled(%Accounts.Membership{mfa_enabled_at: %DateTime{}}), do: :ok
  defp ensure_mfa_enabled(%Accounts.Membership{}), do: {:error, :mfa_not_enabled}

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

  # The second-factor brute-force policy: five attempts per Member per
  # five-minute window, shared by every MFA challenge and step-up (sign-in,
  # disable, regeneration, a reset's local proof) and by both factors, so
  # switching surface or factor doesn't stretch the guessing budget.
  @mfa_challenge_attempt_limit 5
  @mfa_challenge_attempt_window_ms 5 * 60_000

  # A newly inserted row is deliberately born expired. The first locked read
  # resets it from the database's clock, avoiding any dependency on an app
  # node's wall clock while still using a normal schema insert.
  @expired_security_window ~U[2000-01-01 00:00:00.000000Z]

  @doc """
  Internal — spend one attempt from a durable per-Member security window.

  Returns `:ok` through the configured limit. The first rejected attempt is
  `{:error, :rate_limited, :exhausted}` and advances the stored count to
  `limit + 1`; later rejects saturate there as `:capped`. Any persistence error
  is `:store_unavailable`, which callers reject exactly like exhaustion. The
  exhausting attempt writes one rate-limit audit row in the Member's workspace.

  The row lock and database clock make the budget atomic across Portal nodes.
  The test-only rate-limit switch still bypasses it so unrelated async tests do
  not share credential budgets.
  """
  def check_security_attempt(membership, scope, limit, window_ms, context \\ %RequestContext{})

  def check_security_attempt(
        %Accounts.Membership{} = membership,
        scope,
        limit,
        window_ms,
        context
      )
      when scope in @security_attempt_scopes and
             is_integer(limit) and limit > 0 and is_integer(window_ms) and window_ms > 0 and
             is_struct(context, RequestContext) do
    if Emisar.Config.get_env(:emisar, :rate_limit_enabled, true) do
      do_check_security_attempt(membership, scope, limit, window_ms, context)
    else
      :ok
    end
  end

  defp do_check_security_attempt(membership, scope, limit, window_ms, context) do
    commit_security_attempt(membership, scope, limit, window_ms, context)
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, :rate_limited, :store_unavailable}
  end

  defp commit_security_attempt(membership, scope, limit, window_ms, context) do
    Multi.new()
    |> Multi.run(:ensure_window, fn repo, _changes ->
      attrs = %{
        id: Repo.generate_id(),
        membership_id: membership.id,
        scope: scope,
        attempt_count: 0,
        window_started_at: @expired_security_window,
        window_expires_at: @expired_security_window,
        inserted_at: @expired_security_window,
        updated_at: @expired_security_window
      }

      case repo.insert_all(SecurityAttemptWindow, [attrs],
             on_conflict: :nothing,
             conflict_target: [:membership_id, :scope]
           ) do
        {_count, nil} -> {:ok, :ready}
      end
    end)
    |> Multi.run(:window, fn repo, _changes ->
      window_query =
        SecurityAttemptWindow.Query.by_membership_and_scope(membership.id, scope)
        |> SecurityAttemptWindow.Query.lock_for_update()

      case repo.fetch(window_query, SecurityAttemptWindow.Query) do
        {:ok, window} ->
          database_now =
            SecurityAttemptWindow.Query.by_membership_and_scope(membership.id, scope)
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
    |> put_security_attempt_exhausted_audit(membership, scope, limit, window_ms, context)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{attempt: %{outcome: :allowed}}} -> :ok
      {:ok, %{attempt: %{outcome: :exhausted}}} -> {:error, :rate_limited, :exhausted}
      {:ok, %{attempt: %{outcome: :capped}}} -> {:error, :rate_limited, :capped}
      {:error, _reason} -> {:error, :rate_limited, :store_unavailable}
    end
  end

  # One event per scope in `SecurityAttemptWindow.scopes/0`: a scope without one
  # would crash the exhausting attempt instead of refusing it.
  @security_attempt_exhausted_events %{
    mfa_challenge: "user.mfa_rate_limited",
    mfa_enrollment_issue: "user.mfa_rate_limited",
    inbox_step_up: "user.inbox_step_up_rate_limited",
    oidc_identity_step_up_issue: "user.oidc_identity_step_up_rate_limited"
  }

  defp put_security_attempt_exhausted_audit(
         multi,
         %Accounts.Membership{} = membership,
         scope,
         limit,
         window_ms,
         %RequestContext{} = context
       ) do
    event_type = Map.fetch!(@security_attempt_exhausted_events, scope)

    Multi.run(multi, :rate_limit_audit, fn
      repo, %{attempt: %{outcome: :exhausted}} ->
        membership
        |> Audit.Events.member_security_event(event_type, context, %{
          scope: Atom.to_string(scope),
          attempt_limit: limit,
          window_seconds: div(window_ms, 1_000)
        })
        |> repo.insert()

      _repo, _changes ->
        {:ok, nil}
    end)
  end

  @doc """
  Internal — the sign-in second factor, `{:totp, otp}` or `{:recovery_code,
  code}`, for the Member `membership_id` names (`verify_magic_link/4` returned
  it); there is no Subject yet. Only an authorized Member with an enrolled
  authenticator qualifies. Every attempt spends the Member's shared
  five-per-five-minutes window (server-side, so a reload or a fresh socket can't
  reset it), whatever the factor or surface.

  Returns `{:ok, proof}` — an opaque term bound to the enrollment that was just
  verified, which `complete_magic_link_mfa_sign_in/4` rechecks against the
  locked Member before minting anything — `{:error, :rate_limited}` once the
  window is exhausted, `{:error, :replay}` on a reused TOTP, or
  `{:error, :invalid}` otherwise; misses are audited as `user.mfa_failed`.
  """
  def verify_mfa_challenge(membership_id, factor, context \\ %RequestContext{})

  def verify_mfa_challenge(membership_id, factor, %RequestContext{} = context) do
    case Accounts.peek_mfa_enrolled_membership(membership_id) do
      %Accounts.Membership{} = membership ->
        verify_member_mfa_challenge(membership, factor, context)

      nil ->
        {:error, :invalid}
    end
  end

  @doc """
  Verifies a local-MFA challenge for an already-authenticated Member. The
  Subject is the authorization boundary: the factor is always checked against
  the Member its live session belongs to, and the attempt audit uses its request
  context. Returns as `verify_mfa_challenge/3`, or `{:error, :unauthorized}`.
  """
  def verify_current_session_mfa_challenge(factor, %Subject{context: context} = subject) do
    with {:ok, %UserToken{membership: membership}} <- fetch_current_session(subject) do
      verify_member_mfa_challenge(membership, factor, context)
    end
  end

  defp verify_member_mfa_challenge(membership, {:totp, otp}, context) when is_binary(otp) do
    with {:ok, verified} <- verify_mfa(membership, otp, context) do
      {:ok, mfa_proof(verified)}
    end
  end

  defp verify_member_mfa_challenge(membership, {:recovery_code, code}, context)
       when is_binary(code) do
    with {:ok, verified} <- consume_mfa_recovery_code(membership, code, context) do
      {:ok, mfa_proof(verified)}
    end
  end

  defp verify_member_mfa_challenge(_membership, _factor, _context), do: {:error, :invalid}

  @doc """
  Internal — wrap a just-verified local factor or dedicated SSO
  reauthentication in the short-lived, purpose-bound handoff that Accounts
  consumes for one member MFA reset. The target Member's exact enrollment epoch
  and row version make a successful reset, disable, or re-enrollment stale the
  proof instead of turning it into a reusable administrator capability; the
  acting Member and its session are bound too.
  """
  def issue_member_mfa_reset_proof(
        %Accounts.Membership{
          id: target_membership_id,
          account_id: account_id,
          mfa_enabled_at: %DateTime{} = target_mfa_enabled_at,
          updated_at: %DateTime{} = target_updated_at
        },
        source,
        actor_session_token_digest,
        %Subject{
          actor: %Accounts.Membership{},
          account: %Accounts.Account{id: account_id},
          membership_id: actor_membership_id
        }
      )
      when is_binary(actor_membership_id) and is_binary(actor_session_token_digest) do
    with {:ok, source} <- member_mfa_reset_source(source) do
      payload = %{
        actor_membership_id: actor_membership_id,
        account_id: account_id,
        target_membership_id: target_membership_id,
        target_mfa_enabled_at: target_mfa_enabled_at,
        target_updated_at: target_updated_at,
        actor_session_token_digest: actor_session_token_digest,
        source: source
      }

      {:ok,
       Phoenix.Token.sign(
         mfa_proof_secret(),
         @member_mfa_reset_proof_salt,
         {:member_mfa_reset, 2, payload}
       )}
    end
  end

  def issue_member_mfa_reset_proof(_target, _source, _digest, %Subject{}),
    do: {:error, :mfa_reset_proof_stale}

  @doc "Internal — verify and decode the reset-specific handoff; generic MFA proofs use another salt."
  def verify_member_mfa_reset_proof(proof) when is_binary(proof) do
    case Phoenix.Token.verify(mfa_proof_secret(), @member_mfa_reset_proof_salt, proof,
           max_age: @member_mfa_reset_proof_max_age_seconds
         ) do
      {:ok, {:member_mfa_reset, 2, payload}} when is_map(payload) ->
        {:ok, payload}

      _other ->
        {:error, :mfa_reset_proof_stale}
    end
  end

  def verify_member_mfa_reset_proof(_proof), do: {:error, :mfa_reset_proof_stale}

  @doc "Internal — recheck the embedded local proof against the acting Member locked by Accounts."
  def verify_local_member_mfa_reset_source({:local, proof}, %Accounts.Membership{} = actor) do
    case verify_mfa_proof(proof) do
      {:ok, payload} ->
        if payload == mfa_proof_payload(actor),
          do: :ok,
          else: {:error, :mfa_reset_proof_stale}

      _other ->
        {:error, :mfa_reset_proof_stale}
    end
  end

  def verify_local_member_mfa_reset_source(_source, %Accounts.Membership{}),
    do: {:error, :mfa_reset_proof_stale}

  @doc """
  Internal — lock the exact live session of the acting Member bound into a
  member-MFA-reset proof. A local factor may come from any of that Member's
  sessions; an SSO reauthentication only from its SSO session on the very
  identity it proved.
  """
  def lock_member_mfa_reset_session(
        repo,
        token_digest,
        %Accounts.Membership{} = actor,
        source
      )
      when is_binary(token_digest) do
    UserToken.Query.authorized()
    |> UserToken.Query.by_token_digest(token_digest)
    |> UserToken.Query.by_membership(actor.account_id, actor.id)
    |> UserToken.Query.lock_tokens_for_update()
    |> repo.fetch(UserToken.Query)
    |> case do
      {:ok, %UserToken{} = session} ->
        if member_mfa_reset_session_source?(session, source),
          do: {:ok, session},
          else: {:error, :mfa_reset_proof_stale}

      {:error, :not_found} ->
        {:error, :mfa_reset_proof_stale}
    end
  end

  @doc """
  Internal — finish an already-authenticated browser's local-MFA step-up. The
  signed `proof` came from `verify_current_session_mfa_challenge/2`; this
  transaction re-locks the Member and rechecks its exact enrollment before
  touching the session. The `presented_digest` must name the Subject's own live
  session, so a stale/revoked/foreign session cannot be upgraded or resurrected.
  Audits `user.mfa_verified` with the stamp. Returns `{:ok, %UserToken{}}` or
  `{:error, :mfa_proof_stale | :session_not_found}`.

  Factor consumption and this handoff are deliberately two stages, matching the
  email-code MFA completion path. A rare session race may spend one TOTP bucket
  or recovery code but grants nothing; the operator can retry or sign in again.
  """
  def complete_current_session_mfa(
        proof,
        presented_digest,
        %Subject{
          actor: %Accounts.Membership{id: membership_id},
          account: %Accounts.Account{id: account_id},
          context: context
        } = subject
      )
      when is_binary(proof) and is_binary(presented_digest) do
    case mfa_proof_membership_id(proof) do
      ^membership_id ->
        Multi.new()
        |> Multi.run(:membership, fn repo, _changes ->
          lock_mfa_proof_member(repo, account_id, membership_id, proof)
        end)
        |> Multi.run(:session, fn repo, _changes ->
          lock_subject_session(repo, presented_digest, subject)
        end)
        |> Multi.update(:mfa_session, fn %{membership: membership, session: session} ->
          UserToken.Changeset.local_mfa_verified(session, membership.mfa_enabled_at)
        end)
        # A step-up upgrades a LIVE session's assurance and used to leave no
        # trace: "when did this session become MFA-verified" was answerable only
        # from the `auth_user_tokens` row, which the retention sweep deletes.
        # The row commits with the stamp, so a rolled-back stamp claims nothing.
        |> Multi.insert(:audit, fn %{membership: membership} ->
          Audit.Events.member_security_event(membership, "user.mfa_verified", context, %{
            session_verified: true
          })
        end)
        |> Repo.commit_multi()
        |> case do
          {:ok, %{mfa_session: session}} -> {:ok, session}
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:error, :mfa_proof_stale}
    end
  end

  def complete_current_session_mfa(_proof, _presented_digest, %Subject{}),
    do: {:error, :mfa_proof_stale}

  defp lock_mfa_proof_member(repo, account_id, membership_id, proof) do
    with {:ok, locked} <-
           Accounts.fetch_and_lock_active_membership(repo, account_id, membership_id),
         :ok <- ensure_mfa_state_current(locked, proof) do
      {:ok, locked}
    else
      _other -> {:error, :mfa_proof_stale}
    end
  end

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

  defp member_mfa_reset_session_source?(%UserToken{}, {:local, _proof}), do: true

  defp member_mfa_reset_session_source?(
         %UserToken{auth_method: :sso, user_identity_id: identity_id},
         {:sso, %{identity_id: identity_id}}
       )
       when is_binary(identity_id),
       do: true

  defp member_mfa_reset_session_source?(%UserToken{}, _source), do: false

  @doc """
  Internal — the Member a verified MFA proof was minted for, so the sign-in
  boundary can bind completion to the browser that passed factor one without
  learning the proof's shape. Only the complete proof shape names anyone, so a
  bare `%{membership_id: id}` a caller assembled itself is `nil` here and never
  reaches completion; `nil` likewise for anything else that isn't a proof.
  """
  def mfa_proof_membership_id(proof) when is_binary(proof) do
    case verify_mfa_proof(proof) do
      {:ok, {:mfa_sign_in, membership_id, %DateTime{}, %DateTime{}}}
      when is_binary(membership_id) ->
        membership_id

      _ ->
        nil
    end
  end

  def mfa_proof_membership_id(_proof), do: nil

  # The domain signs the Member, its enrollment, and its post-verification row
  # version, so a proof never crosses Members. A caller can read those fields but
  # cannot turn them into a proof without the portal signing secret. Completion
  # verifies the MAC before rebuilding and comparing the payload from the locked
  # row.
  defp mfa_proof(%Accounts.Membership{} = membership) do
    Phoenix.Token.sign(
      mfa_proof_secret(),
      @mfa_sign_in_proof_salt,
      mfa_proof_payload(membership)
    )
  end

  defp mfa_proof_payload(%Accounts.Membership{} = membership),
    do: {:mfa_sign_in, membership.id, membership.mfa_enabled_at, membership.updated_at}

  defp verify_mfa_proof(proof) when is_binary(proof) do
    Phoenix.Token.verify(mfa_proof_secret(), @mfa_sign_in_proof_salt, proof,
      max_age: @mfa_sign_in_proof_max_age_seconds
    )
  end

  defp verify_mfa_proof(_proof), do: {:error, :invalid}

  # Runtime derives this from the portal secret key base. Salt separation keeps
  # MFA proofs independent from the emailed-link signatures sharing the key.
  defp mfa_proof_secret, do: Application.fetch_env!(:emisar, :email_link_secret)

  defp throttle_mfa_challenge(%Accounts.Membership{} = membership, context) do
    throttle_security_attempt(
      membership,
      :mfa_challenge,
      @mfa_challenge_attempt_limit,
      @mfa_challenge_attempt_window_ms,
      context
    )
  end

  defp throttle_security_attempt(membership, scope, limit, window_ms, context) do
    case check_security_attempt(membership, scope, limit, window_ms, context) do
      :ok -> :ok
      {:error, :rate_limited, _reason} -> {:error, :rate_limited}
    end
  end

  # Verifies a TOTP code with replay protection. A bare `Crypto.valid_totp?/2`
  # accepts the same code repeatedly within its 30-second window, so the
  # consume step stamps `mfa_last_used_at` on the **locked** Member row and
  # rejects a second claim of the same bucket — two concurrent submissions of
  # one code can't both pass. Every caller — sign-in (`verify_mfa_challenge/3`)
  # and the post-auth step-ups (`disable_mfa/2`, connection verification, a
  # reset's local proof) — reaches the verifier through here, so the attempt
  # cap is spent exactly once per request and no surface is an unbounded
  # oracle; a capped request never verifies, so it neither stamps the row nor
  # audits a miss it didn't make.
  defp verify_mfa(%Accounts.Membership{} = membership, otp, context) when is_binary(otp) do
    with :ok <- throttle_mfa_challenge(membership, context) do
      # The OTP is NOT validated against this (possibly stale) struct's secret —
      # `verify_and_consume_member_mfa` re-reads the row under a lock and
      # validates + consumes there, so a secret rotated/disabled mid-verify can't
      # slip an old code through. We only AUDIT here from the caller's Member.
      case Accounts.verify_and_consume_member_mfa(membership, otp, []) do
        {:ok, %Accounts.Membership{} = verified} ->
          # Accepted factors are audited as well as misses, so the trail answers
          # "did this Member actually pass MFA, and when".
          record_member_security_event(membership, "user.mfa_verified", context, %{
            factor: "totp"
          })

          {:ok, verified}

        {:error, :replay} ->
          record_member_security_event(membership, "user.mfa_failed", context, %{
            reason: "replay"
          })

          {:error, :replay}

        # Wrong code, MFA disabled, or the row vanished — all "this credential
        # can't complete sign-in" → a single invalid result, audited.
        {:error, _reason} ->
          record_member_security_event(membership, "user.mfa_failed", context, %{
            reason: "invalid_otp"
          })

          {:error, :invalid}
      end
    end
  end

  # One-shot consume of a recovery code: removes it from the Member's stored set
  # under the row lock, so concurrent submissions of the same code serialize
  # and only one wins. Carries the same shared attempt cap as `verify_mfa/3`
  # above, so a capped request keeps its code unspent.
  defp consume_mfa_recovery_code(%Accounts.Membership{} = membership, raw, context)
       when is_binary(raw) do
    with :ok <- throttle_mfa_challenge(membership, context) do
      digest = raw |> String.trim() |> String.downcase() |> Crypto.hash()

      case Accounts.consume_member_mfa_recovery_code(membership, digest,
             audit: fn updated ->
               Audit.Events.member_security_event(
                 updated,
                 "user.mfa_recovery_code_used",
                 context,
                 %{remaining: length(updated.mfa_recovery_codes)}
               )
             end
           ) do
        {:ok, %Accounts.Membership{} = consumed} ->
          {:ok, consumed}

        {:error, :invalid} ->
          # No DB mutation on a wrong code — just an audit row standalone.
          record_member_security_event(membership, "user.mfa_failed", context, %{
            reason: "invalid_recovery_code"
          })

          {:error, :invalid}

        {:error, _reason} ->
          {:error, :invalid}
      end
    end
  end

  # A standalone security event with no transaction to join.
  defp record_member_security_event(membership, event_type, context, payload) do
    {:ok, _event} =
      membership
      |> Audit.Events.member_security_event(event_type, context, payload)
      |> Audit.record()

    :ok
  end
end
