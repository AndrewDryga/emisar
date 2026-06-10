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
  alias Emisar.Users
  alias Emisar.Users.User

  # -- Password sign in -------------------------------------------------

  @doc """
  Looks up a user by email and verifies the password. Returns
  `{:ok, user}` on a match or `{:error, :not_found}` for unknown email
  / wrong password. Pre-auth boundary — no Subject.
  """
  def fetch_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user =
      case Users.fetch_user_by_email(email) do
        {:ok, user} -> user
        {:error, :not_found} -> nil
      end

    # `valid_password?(nil, _)` falls through to Bcrypt.no_user_verify/0
    # so timing is constant whether or not the email matched a row.
    if User.valid_password?(user, password) do
      {:ok, user}
    else
      {:error, :not_found}
    end
  end

  # -- Session tokens ---------------------------------------------------

  @doc """
  Mint a session token and persist it. Returns the raw token for the
  cookie. `metadata` (optional) carries `ip_address` + `user_agent`
  captured from the inbound request so the Profile page can show
  per-session device info; missing keys are tolerated. Pre-Subject
  boundary — the session controller calls this right after verifying
  credentials.
  """
  def create_session_token!(%User{} = user, metadata \\ %{}) do
    {token, digest} = Crypto.session_token()
    Repo.insert!(UserToken.Changeset.session(user, digest, metadata))
    token
  end

  @doc """
  Looks up the user behind a session token. Returns `{:ok, user}` on
  a hit or `{:error, :not_found}` for expired / unknown / non-binary
  tokens. Pre-auth boundary — no Subject.
  """
  def fetch_user_by_session_token(token) when is_binary(token) do
    UserToken.Query.by_token_digest(Crypto.hash(token))
    |> UserToken.Query.by_context("session")
    |> UserToken.Query.not_expired("session")
    |> UserToken.Query.with_joined_user()
    |> UserToken.Query.select_user()
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      %User{} = user -> {:ok, user}
    end
  end

  @doc """
  Drop the session row backing a cookie (sign-out). Pre-auth boundary —
  possession of the cookie value is the authorization.
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
  def record_sign_out(%User{} = user) do
    Audit.log_for_user(user, "user.signed_out")
    :ok
  end

  @doc """
  Audit-records a failed sign-in attempt. If `email` matches a known
  user, the event lands on that user's primary account so an admin can
  see "someone is probing this team member". Unknown emails are silently
  dropped — auditing them would let an attacker enumerate accounts by
  watching their own org's audit log.
  """
  def record_failed_sign_in(email, reason) when is_binary(email) do
    case Users.fetch_user_by_email(email) do
      {:ok, user} ->
        _ = Audit.log_for_user(user, "user.sign_in_failed", payload: %{reason: reason})
        :ok

      {:error, :not_found} ->
        :ok
    end
  end

  def record_failed_sign_in(_, _), do: :ok

  @doc """
  Delete every session token for the user. Returns `{:ok, count}` so a
  caller can compose it into its own transaction via `Multi.run` (the
  team-admin "sign out everywhere" does) — token internals stay private
  to Auth.
  """
  def delete_all_session_tokens(%User{} = user) do
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
  def disconnect_and_revoke_all_sessions(%User{} = user) do
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
  def revoke_and_disconnect_other_sessions!(keep_token, %Subject{actor: %User{} = user})
      when is_binary(keep_token) do
    keep_digest = Crypto.hash(keep_token)
    broadcast_disconnect_for_user(user, except: keep_digest)
    revoke_other_sessions!(user, keep_token)
  end

  @doc """
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
  def broadcast_disconnect_for_user(%User{} = user, opts \\ []) do
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
  def list_sessions_for_user(%Subject{actor: %User{} = user}, opts \\ []) do
    UserToken.Query.by_user_id(user.id)
    |> UserToken.Query.by_context("session")
    |> Repo.list(UserToken.Query, opts)
  end

  @doc """
  Revoke one of the caller's own sessions by id (Profile's per-device
  sign-out). Self-service — the user comes from the subject's own
  actor, and the query is scoped to them so a malicious id can't kill
  another user's session. Returns :ok | {:error, :not_found}.
  """
  def revoke_session(token_id, %Subject{actor: %User{} = user}) do
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
  def revoke_other_sessions!(%User{} = user, keep_token) when is_binary(keep_token) do
    sessions_query =
      UserToken.Query.by_user_id(user.id)
      |> UserToken.Query.by_context("session")
      |> UserToken.Query.except_token_digest(Crypto.hash(keep_token))

    revoke_sessions_atomically!(user, sessions_query)
  end

  def revoke_other_sessions!(%User{} = user, nil) do
    sessions_query =
      UserToken.Query.by_user_id(user.id)
      |> UserToken.Query.by_context("session")

    revoke_sessions_atomically!(user, sessions_query)
  end

  # Wraps the delete + (conditional) audit in one transaction so a row
  # delete-without-audit can't happen on a downstream failure. The
  # audit's `user_fn` resolves the user only when rows were actually
  # revoked — a no-op revoke stays out of the log.
  defp revoke_sessions_atomically!(%User{} = user, sessions_query) do
    {:ok, %{count: count}} =
      Multi.new()
      |> Multi.delete_all(:sessions, sessions_query)
      |> Multi.run(:count, fn _repo, %{sessions: {count, _}} -> {:ok, count} end)
      |> Audit.Multi.log_for_user(:audit, user, "user.other_sessions_revoked",
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

  @doc "Issues a magic-link token. Returns the raw token to email."
  def issue_magic_link_token!(%User{} = user) do
    {raw, digest} = Crypto.email_token()

    {:ok, _} =
      Multi.new()
      |> Multi.insert(:token, UserToken.Changeset.hashed(user, digest, "magic_link", user.email))
      |> Audit.Multi.log_for_user(:audit, user, "user.magic_link_issued")
      |> Repo.commit_multi()

    raw
  end

  @doc "Consumes a magic-link token, returning the user or {:error, reason}."
  def consume_magic_link_token(raw) when is_binary(raw) do
    with {:ok, digest} <- Crypto.email_token_digest(raw) do
      verified_token_multi(digest, "magic_link")
      |> Multi.delete(:deleted_token, fn %{token: token} -> token end)
      |> Audit.Multi.log_for_user(:audit, nil, "user.signed_in",
        user_fn: fn %{token_user: user} -> user end,
        payload_fn: fn _ -> %{method: "magic_link"} end
      )
      |> Repo.commit_multi()
      |> case do
        {:ok, %{token_user: user}} -> {:ok, user}
        {:error, reason} -> {:error, reason}
      end
    else
      :error -> {:error, :invalid_or_expired}
    end
  end

  # -- Password reset ---------------------------------------------------

  @doc """
  Mints a reset-password token for `user` and (by default) audits the
  request as `user.password_reset_requested` with `user` as both actor
  and subject.

  Options:

    * `:audit` (boolean, default true) — set to `false` when the caller
      is an admin-driven path (`Accounts.force_password_reset/2`). Those
      paths emit their own correctly-attributed event
      (`user.password_reset_forced` with admin as actor); the inline
      audit here would otherwise re-record the same action with the
      TARGET user as actor — which is wrong and confusing in the log.
  """
  def issue_password_reset_token!(%User{} = user, opts \\ []) do
    {raw, digest} = Crypto.email_token()

    multi =
      Multi.new()
      |> Multi.insert(
        :token,
        UserToken.Changeset.hashed(user, digest, "reset_password", user.email)
      )

    multi =
      if Keyword.get(opts, :audit, true) do
        Audit.Multi.log_for_user(multi, :audit, user, "user.password_reset_requested")
      else
        multi
      end

    {:ok, _} = Repo.commit_multi(multi)
    raw
  end

  def reset_user_password(raw, password) when is_binary(raw) and is_binary(password) do
    with {:ok, digest} <- Crypto.email_token_digest(raw) do
      verified_token_multi(digest, "reset_password")
      |> Multi.run(:user, fn _repo, %{token_user: user} ->
        Users.reset_user_password(user, password)
      end)
      |> Multi.delete(:deleted_token, fn %{token: token} -> token end)
      |> Multi.delete_all(:sessions, fn %{token_user: user} ->
        UserToken.Query.by_user_id(user.id) |> UserToken.Query.by_context("session")
      end)
      |> Audit.Multi.log_for_user(:audit, nil, "user.password_reset_completed",
        user_fn: fn %{user: user} -> user end
      )
      |> Repo.commit_multi()
      |> case do
        {:ok, %{user: updated}} -> {:ok, updated}
        {:error, reason} -> {:error, reason}
      end
    else
      :error -> {:error, :invalid_or_expired}
    end
  end

  # -- Email confirmation ----------------------------------------------

  def issue_confirmation_token!(%User{} = user) do
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
  def deliver_confirmation_instructions(%User{} = user) do
    token = issue_confirmation_token!(user)
    _ = Emisar.Mailers.UserNotifier.deliver_confirmation_instructions(user, token)
    :ok
  end

  def confirm_user_by_token(raw) when is_binary(raw) do
    with {:ok, digest} <- Crypto.email_token_digest(raw) do
      verified_token_multi(digest, "confirm")
      |> Multi.run(:user, fn _repo, %{token_user: user} -> Users.mark_user_confirmed(user) end)
      |> Multi.delete(:deleted_token, fn %{token: token} -> token end)
      |> Audit.Multi.log_for_user(:audit, nil, "user.email_confirmed",
        user_fn: fn %{user: user} -> user end
      )
      |> Repo.commit_multi()
      |> case do
        {:ok, %{user: confirmed}} -> {:ok, confirmed}
        {:error, reason} -> {:error, reason}
      end
    else
      :error -> {:error, :invalid_or_expired}
    end
  end

  # -- MFA scaffold -----------------------------------------------------

  @doc """
  Generates a fresh TOTP secret for the user. Caller is responsible
  for displaying the QR code; nothing is persisted until
  `enable_mfa/2` confirms the user has the secret.
  """
  def generate_mfa_secret, do: NimbleTOTP.secret()

  # 10 recovery codes is the de facto standard (matches GitHub, Google
  # Workspace, etc). Returned in plaintext exactly once at enable-time;
  # we only persist the digests. Each code's shape (length, encoding,
  # digest) is `Crypto.mfa_recovery_code/0`'s concern.
  @recovery_code_count 10

  @doc """
  Enable TOTP for the user. Verifies the OTP against the secret before
  flipping the bit; returns the freshly-generated **recovery codes**
  (plaintext, 10 single-use base32 strings) along with the user — show
  these once and never again. The plaintext leaves this function and
  the DB never sees it.
  """
  def enable_mfa(%User{} = user, secret, otp) when is_binary(secret) and is_binary(otp) do
    if NimbleTOTP.valid?(secret, otp) do
      {plain_codes, digests} = generate_recovery_codes()

      Multi.new()
      |> Multi.run(:user, fn _repo, _ ->
        Users.update_user_mfa(user, secret, DateTime.utc_now(), digests)
      end)
      |> Audit.Multi.log_for_user(:audit, user, "user.mfa_enabled",
        user_fn: fn %{user: u} -> u end
      )
      |> Repo.commit_multi()
      |> case do
        {:ok, %{user: updated}} -> {:ok, updated, plain_codes}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_otp}
    end
  end

  def disable_mfa(%User{} = user) do
    Multi.new()
    |> Multi.run(:user, fn _repo, _ -> Users.update_user_mfa(user, nil, nil, []) end)
    |> Audit.Multi.log_for_user(:audit, user, "user.mfa_disabled",
      user_fn: fn %{user: u} -> u end
    )
    |> Repo.commit_multi()
    |> case do
      {:ok, %{user: updated}} -> {:ok, updated}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Regenerate the recovery code set (e.g. user lost their printed copy).
  Invalidates the prior codes; returns the new plaintext set once.
  Requires MFA to already be enabled.
  """
  def regenerate_mfa_recovery_codes(%User{mfa_enabled_at: nil}), do: {:error, :mfa_not_enabled}

  def regenerate_mfa_recovery_codes(%User{} = user) do
    {plain_codes, digests} = generate_recovery_codes()

    Multi.new()
    |> Multi.run(:user, fn _repo, _ -> Users.put_user_mfa_recovery_codes(user, digests) end)
    |> Audit.Multi.log_for_user(:audit, user, "user.mfa_recovery_codes_regenerated",
      user_fn: fn %{user: u} -> u end
    )
    |> Repo.commit_multi()
    |> case do
      {:ok, %{user: updated}} -> {:ok, updated, plain_codes}
      {:error, reason} -> {:error, reason}
    end
  end

  defp generate_recovery_codes do
    1..@recovery_code_count
    |> Enum.map(fn _ -> Crypto.mfa_recovery_code() end)
    |> Enum.unzip()
  end

  def mfa_required?(%User{mfa_enabled_at: nil}), do: false
  def mfa_required?(%User{}), do: true

  @doc """
  Verifies a TOTP code with replay protection — `NimbleTOTP.valid?`
  alone accepts the same code multiple times within its 30-second
  window. Stamps `mfa_last_used_at` to the bucketed window and rejects
  any code claiming the same bucket. Returns `:ok` on a fresh code,
  `{:error, :replay}` on duplicate, `{:error, :invalid}` otherwise.

  Pair with `consume_mfa_recovery_code/2` for the lost-device path.
  """
  def verify_mfa(%User{mfa_secret: secret} = user, otp)
      when is_binary(secret) and is_binary(otp) do
    now = DateTime.utc_now()

    cond do
      not NimbleTOTP.valid?(secret, otp) ->
        Audit.log_for_user(user, "user.mfa_failed", payload: %{reason: "invalid_otp"})
        {:error, :invalid}

      replayed?(user, now) ->
        Audit.log_for_user(user, "user.mfa_failed", payload: %{reason: "replay"})
        {:error, :replay}

      true ->
        case Users.record_user_mfa_consumed(user, now) do
          {:ok, _} -> :ok
          {:error, _} -> {:error, :invalid}
        end
    end
  end

  def verify_mfa(_, _), do: {:error, :invalid}

  # TOTP buckets are 30 seconds wide. If we already stamped within the
  # current bucket, the same code is being submitted twice.
  defp replayed?(%User{mfa_last_used_at: nil}, _now), do: false

  defp replayed?(%User{mfa_last_used_at: prev}, now) do
    div(DateTime.to_unix(prev), 30) == div(DateTime.to_unix(now), 30)
  end

  @doc """
  One-shot consume a recovery code. Returns `:ok` if it matched (and
  removes it from the user's stored set), `{:error, :invalid}` otherwise.
  Constant-time comparison protects against length/prefix probes.
  """
  def consume_mfa_recovery_code(%User{mfa_recovery_codes: codes} = user, raw)
      when is_list(codes) and is_binary(raw) do
    digest = Crypto.hash(String.downcase(String.trim(raw)))

    matched? = Enum.any?(codes, &Crypto.secure_compare(&1, digest))

    if matched? do
      remaining = Enum.reject(codes, &Crypto.secure_compare(&1, digest))

      Multi.new()
      |> Multi.run(:user, fn _repo, _ -> Users.put_user_mfa_recovery_codes(user, remaining) end)
      |> Audit.Multi.log_for_user(:audit, user, "user.mfa_recovery_code_used",
        user_fn: fn %{user: u} -> u end,
        payload_fn: fn _ -> %{remaining: length(remaining)} end
      )
      |> Repo.commit_multi()
      |> case do
        {:ok, _} -> :ok
        {:error, _} -> {:error, :invalid}
      end
    else
      # No DB mutation on a wrong code — just an audit row standalone.
      Audit.log_for_user(user, "user.mfa_failed", payload: %{reason: "invalid_recovery_code"})
      {:error, :invalid}
    end
  end

  def consume_mfa_recovery_code(_, _), do: {:error, :invalid}
end
