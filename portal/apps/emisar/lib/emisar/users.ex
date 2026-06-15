defmodule Emisar.Users do
  @moduledoc """
  User identity: registration, profile/credential self-service, sign-in
  recording, and the user-row internals the Auth and Accounts flows
  compose into their transactions.

  Identity is deliberately **cross-account** — a user belongs to tenants
  only through `Emisar.Accounts.Membership`, so nothing here is scoped by
  account. Public mutations are either *self-service* (the user is the
  `%Subject{}`'s own actor — that match is the authorization, per
  AGENTS.md §1.2) or *pre-Subject boundary* calls (registration,
  sign-in) where the web layer hasn't resolved a tenant yet. Tenant
  membership, invitations, and team administration live in
  `Emisar.Accounts`.
  """
  alias Ecto.Multi
  alias Emisar.{Audit, Crypto, Repo, RequestContext}
  alias Emisar.Auth.Subject
  alias Emisar.Users.User

  # -- Reads -------------------------------------------------------------

  def fetch_user_by_id(id) do
    if Repo.valid_uuid?(id) do
      User.Query.not_deleted()
      |> User.Query.by_id(id)
      |> Repo.fetch(User.Query)
    else
      {:error, :not_found}
    end
  end

  def fetch_user_by_email(email) when is_binary(email) do
    User.Query.not_deleted()
    |> User.Query.by_email(email)
    |> Repo.fetch(User.Query)
  end

  @doc """
  Batch resolver returning `%{user_id => display_name}` for the
  supplied ids. Falls back to email when full_name is blank.

  Intentionally subjectless — the caller (Audit's reference resolver)
  already authorized an account-scoped listing and only projects labels
  for ids it trusts.
  """
  def user_labels_for_ids(ids) when is_list(ids) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    case ids do
      [] ->
        %{}

      ids ->
        User.Query.not_deleted()
        |> User.Query.by_ids(ids)
        |> Repo.all()
        |> Map.new(fn user -> {user.id, user.full_name || user.email} end)
    end
  end

  # -- Registration + sign-in (pre-Subject boundary) ----------------------

  def register_user(attrs) do
    %User{}
    |> User.Changeset.registration(attrs)
    |> Repo.insert()
  end

  @doc """
  Stamp the user's last sign-in and audit `user.signed_in` (with the auth
  `method` — `"password"`, `"password+mfa"`, `"magic_link"`) in one
  transaction. The audit row is silently skipped for a user with no active
  membership (no account to scope it to), matching `Audit.log_for_user/3`.
  Sign-in is the one mutation the web layer triggers pre-Subject, so the
  audit trail is this function's concern — controllers never write audit
  rows themselves.
  """
  def record_sign_in(%User{} = user, method, context \\ %RequestContext{})
      when is_binary(method) do
    Multi.new()
    |> Multi.update(:user, User.Changeset.sign_in(user))
    |> Audit.Multi.log_for_user(:audit, user, "user.signed_in",
      extra: [payload: %{method: method}, context: context]
    )
    |> Repo.commit_multi()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, reason} -> {:error, reason}
    end
  end

  # -- Self-service mutations ---------------------------------------------

  @doc """
  Update the caller's own profile fields. Self-service — the user is the
  subject's own actor; admins use `Accounts.update_user_as_admin/3` for
  teammates.
  """
  def update_user_profile(attrs, %Subject{actor: %User{id: user_id}} = subject) do
    User.Query.not_deleted()
    |> User.Query.by_id(user_id)
    |> Repo.fetch_and_update(User.Query,
      with: &User.Changeset.profile(&1, attrs),
      audit: fn updated ->
        Audit.user_changeset(updated, "user.profile_updated",
          context: subject.context,
          payload: %{full_name: updated.full_name}
        )
      end
    )
  end

  @doc """
  Change the caller's own sign-in email after verifying their current
  password. Returns `{:ok, user} | {:error, :invalid_current_password}
  | {:error, %Ecto.Changeset{}}`. Self-service — the user is the subject's
  own actor; the current-password check is the proof-of-control gate.

  Audits success (`user.email_changed`) with both addresses for traceability,
  and failed-password attempts (`user.email_change_failed`) since wrong-password
  on the email-change form is a credential probe worth seeing.
  """
  def update_user_email(
        new_email,
        current_password,
        %Subject{actor: %User{id: user_id} = user} = subject
      )
      when is_binary(new_email) and is_binary(current_password) do
    User.Query.not_deleted()
    |> User.Query.by_id(user_id)
    |> Repo.fetch_and_update(User.Query,
      with: fn loaded_user ->
        if User.valid_password?(loaded_user, current_password),
          do: User.Changeset.email(loaded_user, %{email: new_email}),
          else: :invalid_current_password
      end,
      # `changeset.data` is the locked pre-update row — the accurate "from",
      # not `user.email` off the (possibly stale) socket-snapshot subject.
      audit: fn updated, changeset ->
        Audit.user_changeset(updated, "user.email_changed",
          context: subject.context,
          payload: %{from: changeset.data.email, to: updated.email}
        )
      end
    )
    |> case do
      {:error, :invalid_current_password} ->
        # Failed-credential probe — log it standalone since the
        # transaction rolled back without an audit row.
        Audit.log_for_user(user, "user.email_change_failed",
          context: subject.context,
          payload: %{reason: "invalid_current_password"}
        )

        {:error, :invalid_current_password}

      other ->
        other
    end
  end

  @doc """
  Change the caller's own sign-in password after verifying the current
  one. Returns `{:ok, user} | {:error, :invalid_current_password}
  | {:error, %Ecto.Changeset{}}` — length/confirmation problems come back
  as changeset field errors from `User.Changeset.password/2`.

  Audits success (`user.password_changed`) and audit-records bad
  current-password attempts (`user.password_change_failed`) — wrong
  current-password on this form is a real-credential probe worth seeing.

  The caller is responsible for revoking other sessions after success —
  a successful password change implies "the old credential is blown",
  so every other device should sign out. Self-service — the user is the
  subject's own actor.
  """
  def change_user_password(
        current_password,
        new_password,
        %Subject{
          actor: %User{id: user_id} = user
        } = subject
      )
      when is_binary(current_password) and is_binary(new_password) do
    User.Query.not_deleted()
    |> User.Query.by_id(user_id)
    |> Repo.fetch_and_update(User.Query,
      with: fn loaded_user ->
        if User.valid_password?(loaded_user, current_password),
          do: User.Changeset.password(loaded_user, %{password: new_password}),
          else: :invalid_current_password
      end,
      audit: &Audit.user_changeset(&1, "user.password_changed", context: subject.context)
    )
    |> case do
      {:error, :invalid_current_password} ->
        # Failed-credential probe — log it standalone since the
        # transaction rolled back without an audit row.
        Audit.log_for_user(user, "user.password_change_failed",
          context: subject.context,
          payload: %{reason: "invalid_current_password"}
        )

        {:error, :invalid_current_password}

      other ->
        other
    end
  end

  # -- Form builders -------------------------------------------------------

  def change_user(%User{} = user, attrs \\ %{}) do
    User.Changeset.registration(user, attrs, hash_password: false)
  end

  @doc """
  Validation-only changeset for a password change. `hash_password: false`
  keeps it pure — no bcrypt, no `:password` consumed — so it validates
  length + confirmation and round-trips the field for redisplay. The
  actual change, with the current-password challenge and audit, is
  `change_user_password/3`.
  """
  def change_password(%User{} = user, attrs \\ %{}) do
    User.Changeset.password(user, attrs, hash_password: false)
  end

  # -- Internal (Auth flows) ----------------------------------------------
  # User-credential writes the Auth context performs after its own gates
  # (token possession, password/TOTP verification). Auth composes them
  # into its token transactions via `Multi.run`, so each runs inside the
  # caller's transaction — the User changeset internals stay private to
  # Users. Never exposed to LiveView/controllers/MCP.

  @doc "Internal — Auth: set a new password after a verified reset token."
  def reset_user_password(%User{} = user, password) when is_binary(password) do
    user |> User.Changeset.password(%{password: password}) |> Repo.update()
  end

  @doc "Internal — Auth: mark the user's email confirmed (token flow)."
  def mark_user_confirmed(%User{} = user) do
    user |> User.Changeset.confirm() |> Repo.update()
  end

  @doc """
  Internal — Auth: enable MFA (secret + enrolled-at + recovery digests)
  or disable (nils), under the row lock. `opts[:audit]` supplies the
  event changeset — MFA flips are credential-grade and always audited.
  """
  def update_user_mfa(user_id, secret, enabled_at, recovery_code_digests, opts) do
    User.Query.not_deleted()
    |> User.Query.by_id(user_id)
    |> Repo.fetch_and_update(User.Query,
      with: &User.Changeset.mfa(&1, secret, enabled_at, recovery_code_digests),
      audit: Keyword.fetch!(opts, :audit)
    )
  end

  @doc """
  Internal — Auth: replace the stored MFA recovery-code digests under
  the row lock. Refuses with `:mfa_not_enabled` when MFA isn't on —
  judged on the locked row, not the caller's snapshot.
  """
  def put_user_mfa_recovery_codes(user_id, digests, opts) when is_list(digests) do
    User.Query.not_deleted()
    |> User.Query.by_id(user_id)
    |> Repo.fetch_and_update(User.Query,
      with: &mfa_recovery_codes_when_enabled(&1, digests),
      audit: Keyword.fetch!(opts, :audit)
    )
  end

  # Judged on the locked row, not the caller's snapshot.
  defp mfa_recovery_codes_when_enabled(%User{mfa_enabled_at: nil}, _digests),
    do: :mfa_not_enabled

  defp mfa_recovery_codes_when_enabled(%User{} = loaded_user, digests),
    do: User.Changeset.mfa_recovery_codes(loaded_user, digests)

  @doc """
  Internal — Auth: one-shot consume of a recovery-code digest under the
  row lock — two concurrent submissions of the same code serialize and
  the loser gets `:invalid`. `opts[:audit]` supplies the success event
  (the updated row carries the remaining digests for its payload).
  """
  def consume_user_mfa_recovery_code(user_id, digest, opts) when is_binary(digest) do
    User.Query.not_deleted()
    |> User.Query.by_id(user_id)
    |> Repo.fetch_and_update(User.Query,
      with: fn loaded_user ->
        codes = loaded_user.mfa_recovery_codes || []

        if Enum.any?(codes, &Crypto.secure_compare(&1, digest)) do
          remaining = Enum.reject(codes, &Crypto.secure_compare(&1, digest))
          User.Changeset.mfa_recovery_codes(loaded_user, remaining)
        else
          :invalid
        end
      end,
      audit: Keyword.fetch!(opts, :audit)
    )
  end

  @doc """
  Internal — Auth: stamp the most recent successful TOTP under the row
  lock — the replay guard. A second claim of the same 30-second TOTP
  bucket aborts with `:replay`, judged on the locked row so two
  concurrent submissions of one code can't both pass.
  """
  def record_user_mfa_consumed(user_id, %DateTime{} = at) do
    User.Query.not_deleted()
    |> User.Query.by_id(user_id)
    |> Repo.fetch_and_update(User.Query,
      with: fn loaded_user ->
        if totp_bucket(loaded_user.mfa_last_used_at) == totp_bucket(at),
          do: :replay,
          else: User.Changeset.mfa_consumed(loaded_user, at)
      end
    )
  end

  # TOTP buckets are 30 seconds wide — NimbleTOTP's verification window.
  defp totp_bucket(nil), do: nil
  defp totp_bucket(%DateTime{} = at), do: div(DateTime.to_unix(at), 30)

  # -- Internal (Accounts flows) --------------------------------------------
  # User-row writes the Accounts context performs from its invitation and
  # team-administration flows. Accounts owns the authorization + audit
  # semantics (who did what to which member) and composes these via
  # `Multi.run` / `:audit` callbacks; the row mechanics and changesets
  # stay private to Users.

  @doc """
  Internal — Accounts invite: the user by email, or a placeholder
  (unconfirmed, no password) for the invitation to hang off.

  Two concurrent invites can race on the same NEW email; the insert is
  ON CONFLICT DO NOTHING (a raw unique violation would abort the whole
  invite transaction) and we re-read the row that won — ours or the
  concurrent one.
  """
  def fetch_or_create_user_by_email(email) when is_binary(email) do
    changeset = User.Changeset.registration(%User{}, %{email: email}, hash_password: false)

    with {:error, :not_found} <- fetch_user_by_email(email),
         {:ok, _} <- Repo.insert(changeset, on_conflict: :nothing) do
      fetch_user_by_email(email)
    end
  end

  @doc """
  Internal — Accounts invitation accept: set the invited user's
  full_name + password and mark them confirmed (accepting the invite
  proves they own the email). Two updates inside the caller's
  transaction.
  """
  def register_invited_user(%User{} = user, %{} = attrs) do
    registration = User.Changeset.registration(user, attrs)

    with {:ok, user} <- Repo.update(registration) do
      user |> User.Changeset.confirm() |> Repo.update()
    end
  end

  @doc """
  Internal — Accounts team admin: locked profile edit on a member's user
  row. The caller supplies the `:audit` changeset fun (its event carries
  the acting subject + membership); field whitelisting is
  `User.Changeset.profile/2` (full_name only).
  """
  def update_user_profile_as_admin(user_id, attrs, opts) when is_map(attrs) do
    User.Query.not_deleted()
    |> User.Query.by_id(user_id)
    |> Repo.fetch_and_update(User.Query,
      with: &User.Changeset.profile(&1, attrs),
      audit: Keyword.fetch!(opts, :audit)
    )
  end

  @doc """
  Internal — Accounts team admin: null out the member's password hash
  under the row lock. `User.valid_password?/2` guards on
  `is_binary(hashed_password)`, so the old credential stops working the
  moment this commits. The caller supplies `:audit` (forced-reset event
  with the acting subject) and `:after_commit` (session kill + reset
  email).
  """
  def clear_user_password(user_id, opts) do
    User.Query.not_deleted()
    |> User.Query.by_id(user_id)
    |> Repo.fetch_and_update(User.Query,
      with: &User.Changeset.clear_password/1,
      audit: Keyword.fetch!(opts, :audit)
    )
  end

  @doc """
  Internal — Accounts team admin: clear the member's MFA enrollment
  (secret + enrolled-at + recovery digests, replay stamp) under the row
  lock, so a member locked out of both their authenticator and recovery
  codes re-enrolls a fresh factor on next sign-in. Same write as the
  self-service `Auth.disable_mfa/1` (`User.Changeset.mfa/4` with nils),
  but driven by an admin — the caller supplies the `:audit` event
  (`user.mfa_reset_by_admin`, with the acting subject + membership).
  """
  def reset_user_mfa(user_id, opts) do
    User.Query.not_deleted()
    |> User.Query.by_id(user_id)
    |> Repo.fetch_and_update(User.Query,
      with: &User.Changeset.mfa(&1, nil, nil, []),
      audit: Keyword.fetch!(opts, :audit)
    )
  end
end
