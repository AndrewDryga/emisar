defmodule Emisar.Auth do
  @moduledoc """
  Authentication: sign in/up flows, session tokens, magic links,
  password resets, email confirmation, MFA scaffold.

  All token types share `user_tokens` storage; `context` disambiguates
  semantics + validity window.
  """
  alias Ecto.Multi
  alias Emisar.Audit
  alias Emisar.Auth.Subject
  alias Emisar.Auth.UserToken
  alias Emisar.Crypto
  alias Emisar.Repo
  alias Emisar.RequestContext
  alias Emisar.Telemetry
  alias Emisar.Users
  require Logger

  # -- Session tokens ---------------------------------------------------

  @doc """
  Internal — `EmisarWeb.UserAuth` mints the session row right after verifying
  credentials; the session token IS the credential, so there's no Subject yet.
  Returns the raw token for the cookie. `auth_method` (how the session was
  authenticated) and `mfa` (was a second factor verified) are required
  provenance — stamped onto the token so every later request resolves how it
  signed in; `opts` carry the SSO-only `:user_identity_id`. `metadata`
  (optional) carries `ip_address` + `user_agent` for the Profile sessions
  list; missing keys are tolerated.
  """
  def create_session_token!(%Users.User{} = user, auth_method, mfa, metadata \\ %{}, opts \\ []) do
    {token, digest} = Crypto.session_token()
    Repo.insert!(UserToken.Changeset.session(user, digest, metadata, auth_method, mfa, opts))
    token
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
  Internal — `EmisarWeb.UserAuth` drops the session row backing a cookie on
  sign-out; possession of the cookie value IS the authorization, so no Subject.
  """
  def delete_session_token(token) when is_binary(token) do
    UserToken.Query.by_token_digest(Crypto.hash(token))
    |> UserToken.Query.by_context("session")
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Audit-records that a user signed out of this session. Called by
  `EmisarWeb.UserAuth.log_out_user/1` before the token is dropped so the
  event is attributable to the user that owned it.
  """
  def record_sign_out(%Users.User{} = user, context \\ %RequestContext{}) do
    Audit.log_for_user(user, "user.signed_out", context: context)
    :ok
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
  Live-session terminator for "user must lose access RIGHT NOW" paths
  (admin suspend, force-password-reset, account-wide password change).
  Disconnects every active LiveView socket for the user via PubSub
  before deleting the underlying token rows — so a kept-open browser
  tab can't keep streaming PubSub updates after the user is killed at
  the DB layer.

  Pair with the standard `delete_all_session_tokens/1` for the auth
  cookie invalidation; the broadcast is best-effort and idempotent.
  """
  def disconnect_and_revoke_all_sessions(%Users.User{} = user) do
    broadcast_disconnect_for_user(user)
    {:ok, _count} = delete_all_session_tokens(user)
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
    broadcast_disconnect_for_user(user, except: keep_digest)
    revoke_other_sessions!(user, keep_token, subject.context)
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
    skip_digest = Keyword.get(opts, :except)

    topics =
      UserToken.Query.by_user_id(user.id)
      |> UserToken.Query.by_context("session")
      |> Repo.all()
      |> Enum.reject(&(&1.token == skip_digest))
      |> Enum.map(&live_socket_topic(&1.token))

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
  The caller's own active sessions, newest first (Profile's device
  list). Self-service — the user is the subject's own actor. The raw
  token is never surfaced — only the row id (for revocation) and
  inserted_at (display). Returns `{:ok, [token], %Paginator.Metadata{}}`
  per the context-function convention.
  """
  def list_sessions_for_user(%Subject{actor: %Users.User{} = user}, opts \\ []) do
    UserToken.Query.by_user_id(user.id)
    |> UserToken.Query.by_context("session")
    |> UserToken.Query.with_valid_auth_method()
    |> Repo.list(UserToken.Query, opts)
  end

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
        {:error, :not_found} -> {:error, :not_found}
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

  # Online-guess budget for the 6-digit magic-link secret. The nonce carries
  # the real entropy; this caps brute-force by anyone who somehow has it.
  @magic_link_attempts 5

  @doc """
  Issues a split-code magic-link token. Returns `{token_id, nonce, secret}`: the
  caller keeps `nonce` browser-side (a short-lived cookie) and emails the
  `secret` (a 6-digit code) plus a link carrying `token_id` + `secret`. Deletes
  any prior outstanding magic-link token for the user (single outstanding).
  """
  def issue_magic_link(%Users.User{} = user, context \\ %RequestContext{}) do
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
          {:ok, user} -> {:ok, {:ok, user}}
          # A soft-deleted user behind a live token reads as a dead link.
          {:error, :not_found} -> {:ok, {:error, :invalid_or_expired}}
        end
      else
        # Wrong nonce or secret → spend one attempt. Returns `{:ok, …}` so the
        # decrement COMMITS (a Multi rollback would undo the spend).
        {:ok, _} = repo.update(UserToken.Changeset.decrement_attempts(token))
        {:ok, {:error, :invalid_or_expired}}
      end
    end)
    |> Audit.Multi.log_for_user(:audit, nil, "user.signed_in",
      extra: [context: context],
      user_fn: fn
        %{outcome: {:ok, %Users.User{} = user}} -> user
        _ -> nil
      end,
      payload_fn: fn _ -> %{method: "magic_link"} end
    )
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

  # -- Email-change step-up --------------------------------------------

  # Online-guess budget for the 6-digit email-change step-up code.
  @email_change_attempts 5

  @doc """
  Mints + emails a 6-digit step-up code to the user's CURRENT address, binding
  it to `new_email`. A self-service email change must re-enter it first, so the
  identity-defining field (it controls every future magic link) gets a
  credential-grade gate a stolen session alone can't pass. Deletes any prior
  outstanding email-change code (single outstanding). Best-effort delivery;
  returns `:ok`.
  """
  def issue_email_change_code(new_email, %Subject{actor: %Users.User{} = user} = subject)
      when is_binary(new_email) do
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

    _ = Emisar.Mailers.UserNotifier.deliver_email_change_code(user, code)
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
    _ = Emisar.Mailers.UserNotifier.deliver_confirmation_instructions(user, token)
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
        audit: &Audit.user_changeset(&1, "user.mfa_enabled", context: subject.context)
      )
      |> case do
        {:ok, updated} -> {:ok, updated, plain_codes}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_otp}
    end
  end

  @doc "Disable TOTP for the caller. Self-service — the user is the subject's own actor."
  def disable_mfa(%Subject{actor: %Users.User{} = user} = subject) do
    Users.update_user_mfa(user.id, nil, nil, [],
      audit: &Audit.user_changeset(&1, "user.mfa_disabled", context: subject.context)
    )
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
        &Audit.user_changeset(&1, "user.mfa_recovery_codes_regenerated", context: subject.context)
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

  @doc """
  Verifies a second-factor TOTP code with replay protection. A bare
  `Crypto.valid_totp?/2` accepts the same code repeatedly within its
  30-second window, so the consume step stamps `mfa_last_used_at` on
  the **locked** row and rejects a second claim of the same bucket —
  two concurrent submissions of one code can't both pass. Returns `:ok`
  on a fresh code, `{:error, :replay}` on duplicate, `{:error,
  :invalid}` otherwise.

  Pre-Subject — this is the sign-in second factor, so it takes the
  partially-authenticated `%Users.User{}` (no tenant resolved yet). Pair with
  `consume_mfa_recovery_code/2` for the lost-device path.
  """
  def verify_mfa(user, otp, context \\ %RequestContext{})

  def verify_mfa(%Users.User{} = user, otp, context) when is_binary(otp) do
    # The OTP is NOT validated against this (possibly stale) struct's secret —
    # `verify_and_consume_mfa` re-reads the row under a lock and validates +
    # consumes there, so a secret rotated/disabled mid-verify can't slip an old
    # code through. We only AUDIT here from the caller's user.
    case Users.verify_and_consume_mfa(user.id, otp, DateTime.utc_now()) do
      :ok ->
        :ok

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

  def verify_mfa(_, _, _), do: {:error, :invalid}

  @doc """
  One-shot consume a recovery code. Returns `:ok` if it matched (and
  removes it from the user's stored set under the row lock — concurrent
  submissions of the same code serialize and only one wins),
  `{:error, :invalid}` otherwise. Pre-Subject — the sign-in lost-device
  fallback, so it takes the partially-authenticated `%Users.User{}`.
  """
  def consume_mfa_recovery_code(user, raw, context \\ %RequestContext{})

  def consume_mfa_recovery_code(%Users.User{} = user, raw, context) when is_binary(raw) do
    digest = Crypto.hash(String.downcase(String.trim(raw)))

    case Users.consume_user_mfa_recovery_code(user.id, digest,
           audit: fn updated ->
             Audit.user_changeset(updated, "user.mfa_recovery_code_used", %{
               context: context,
               payload: %{remaining: length(updated.mfa_recovery_codes)}
             })
           end
         ) do
      {:ok, _} ->
        :ok

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

  def consume_mfa_recovery_code(_, _, _), do: {:error, :invalid}
end
