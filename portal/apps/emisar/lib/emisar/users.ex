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

  @doc "Internal — identity lookup composed by Auth/Accounts internals and the auth boundary; cross-account, no subject."
  def fetch_user_by_id(id) do
    if Repo.valid_uuid?(id) do
      User.Query.not_deleted()
      |> User.Query.by_id(id)
      |> Repo.fetch(User.Query)
    else
      {:error, :not_found}
    end
  end

  @doc "Internal — email identity lookup composed by Auth/Accounts internals and the auth boundary; cross-account, no subject."
  def fetch_user_by_email(email) when is_binary(email) do
    User.Query.not_deleted()
    |> User.Query.by_email(email)
    |> Repo.fetch(User.Query)
  end

  @doc """
  Internal — label resolver for Audit/dispatch: batch resolver returning
  `%{user_id => display_name}` for the supplied ids (falls back to email
  when full_name is blank). Takes ids, not a subject — the caller (Audit's
  reference resolver) already authorized an account-scoped listing and only
  projects labels for ids it trusts.
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
        |> Map.new(fn user -> {user.id, user_label(user)} end)
    end
  end

  defp user_label(%User{full_name: full_name, email: email}) when is_binary(full_name) do
    if String.trim(full_name) == "", do: email, else: full_name
  end

  defp user_label(%User{email: email}), do: email

  # -- Registration + sign-in (pre-Subject boundary) ----------------------

  @doc "Internal — registration: the auth boundary creates the user before any subject/tenant exists (pre-auth)."
  def register_user(attrs) do
    %User{}
    |> User.Changeset.registration(attrs)
    |> Repo.insert()
  end

  @doc """
  Stamp the user's last sign-in and audit `user.signed_in` (with the auth
  `method` — `"magic_link"`) in one
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
        Audit.user_changesets(updated, "user.profile_updated",
          context: subject.context,
          payload: %{full_name: updated.full_name}
        )
      end
    )
  end

  @doc """
  Apply a new sign-in email to the caller's own user row. Returns `{:ok, user} |
  {:error, %Ecto.Changeset{}}`. Self-service (the user is the subject's own actor)
  and the low-level write ONLY — the step-up that proves control (TOTP for an MFA
  user, an emailed one-time code otherwise) is enforced by the sole caller,
  `Auth.confirm_email_change/3`, so this is never reached without a verified
  challenge. Audits `user.email_changed` with both addresses for traceability.
  """
  def update_user_email(new_email, %Subject{actor: %User{id: user_id}} = subject)
      when is_binary(new_email) do
    User.Query.not_deleted()
    |> User.Query.by_id(user_id)
    |> Repo.fetch_and_update(User.Query,
      with: &User.Changeset.email(&1, %{email: new_email}),
      # `changeset.data` is the locked pre-update row — the accurate "from",
      # not `user.email` off the (possibly stale) socket-snapshot subject.
      audit: fn updated, changeset ->
        Audit.user_changesets(updated, "user.email_changed",
          context: subject.context,
          payload: %{from: changeset.data.email, to: updated.email}
        )
      end
    )
  end

  @doc """
  Internal — Auth signup recovery: update an unconfirmed registration's email
  before the first magic-link proof. Returns `{:ok, user} | {:error,
  :already_confirmed | :not_found | %Ecto.Changeset{}}`.
  """
  def correct_unconfirmed_user_email(user_id, new_email, opts \\ [])
      when is_binary(new_email) do
    if Repo.valid_uuid?(user_id) do
      context = Keyword.get(opts, :context, %RequestContext{})

      User.Query.not_deleted()
      |> User.Query.by_id(user_id)
      |> Repo.fetch_and_update(User.Query,
        with: &unconfirmed_email(&1, new_email),
        audit: fn updated, changeset ->
          Audit.user_changesets(updated, "user.email_changed",
            context: context,
            payload: %{
              from: changeset.data.email,
              to: updated.email,
              method: "signup_correction"
            }
          )
        end
      )
    else
      {:error, :not_found}
    end
  end

  # -- Form builders -------------------------------------------------------

  def change_user(%User{} = user, attrs \\ %{}) do
    User.Changeset.registration(user, attrs)
  end

  # -- Internal (Auth flows) ----------------------------------------------
  # User-credential writes the Auth context performs after its own gates
  # (token possession, password/TOTP verification). Auth composes them
  # into its token transactions via `Multi.run`, so each runs inside the
  # caller's transaction — the User changeset internals stay private to
  # Users. Never exposed to LiveView/controllers/MCP.

  @doc "Internal — Auth: mark the user's email confirmed (token flow)."
  def mark_user_confirmed(%User{} = user) do
    user |> User.Changeset.confirm() |> Repo.update()
  end

  @doc """
  Internal — SSO: provision a FRESH user for a just-in-time SSO login. Never
  matches an existing user by email (the takeover guard, §9 C1) — a colliding
  email surfaces as `:email_taken`, never a silent merge. Composed into the
  SSO context's JIT `Multi` via `Multi.run`.
  """
  def provision_sso_user(attrs) do
    changeset = User.Changeset.sso_create(attrs)

    case Repo.insert(changeset) do
      {:ok, %User{} = user} -> {:ok, user}
      {:error, %Ecto.Changeset{} = changeset} -> map_sso_provision_error(changeset)
    end
  end

  defp map_sso_provision_error(changeset) do
    if Repo.Changeset.unique_constraint_error?(changeset),
      do: {:error, :email_taken},
      else: {:error, changeset}
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
  Internal — Auth: the sign-in second factor's authoritative verify+consume in
  ONE locked user-row op. Under the lock, confirm MFA is still enabled, validate
  the OTP against the row's CURRENT `mfa_secret`, reject a replay of the code's
  30-second bucket, and stamp `mfa_last_used_at`. Validating here (not against a
  possibly-stale caller struct) closes the rotate/disable-mid-verify race — an
  OTP from a just-disabled or just-rotated secret can't complete sign-in, and
  two concurrent submissions of one code can't both pass. Returns
  `:ok | {:error, :replay | :invalid | :not_found}`.
  """
  def verify_and_consume_mfa(user_id, otp, %DateTime{} = at) when is_binary(otp) do
    User.Query.not_deleted()
    |> User.Query.by_id(user_id)
    |> Repo.fetch_and_update(User.Query, with: &mfa_verify_and_consume(&1, otp, at))
    |> case do
      {:ok, _user} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Runs on the LOCKED row — any non-changeset return aborts `fetch_and_update`
  # as `{:error, that_value}`.
  defp mfa_verify_and_consume(%User{mfa_enabled_at: nil}, _otp, _at), do: :invalid

  defp mfa_verify_and_consume(%User{mfa_secret: secret} = loaded_user, otp, at)
       when is_binary(secret) do
    cond do
      not Crypto.valid_totp?(secret, otp) -> :invalid
      totp_bucket(loaded_user.mfa_last_used_at) == totp_bucket(at) -> :replay
      true -> User.Changeset.mfa_consumed(loaded_user, at)
    end
  end

  defp mfa_verify_and_consume(%User{}, _otp, _at), do: :invalid

  defp unconfirmed_email(%User{confirmed_at: nil} = user, new_email),
    do: User.Changeset.email(user, %{email: new_email})

  defp unconfirmed_email(%User{}, _new_email), do: :already_confirmed

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
    changeset = User.Changeset.registration(%User{}, %{email: email})

    with {:error, :not_found} <- fetch_user_by_email(email),
         {:ok, _} <- Repo.insert(changeset, on_conflict: :nothing) do
      fetch_user_by_email(email)
    end
  end

  @doc """
  Internal — Accounts invitation accept: set the invited user's full_name
  and mark them confirmed (accepting the invite proves they own the email;
  they sign in via magic link). Two updates inside the caller's transaction.
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
  Internal — SSO directory sync: replace the user's display name with the
  IdP-sent one (SCIM owns a synced user's profile). No-op `{:ok, user}` when
  the name already matches — no write, no audit. The caller supplies `:audit`.
  Returns `{:ok, user} | {:error, :not_found | %Ecto.Changeset{}}`.
  """
  def sync_user_full_name(user_id, full_name, opts) when is_binary(full_name) do
    User.Query.not_deleted()
    |> User.Query.by_id(user_id)
    |> Repo.fetch_and_update(User.Query,
      with: &sync_full_name_changeset(&1, full_name),
      audit: Keyword.fetch!(opts, :audit)
    )
    |> case do
      {:error, {:noop, %User{} = user}} -> {:ok, user}
      other -> other
    end
  end

  # An already-matching name rides fetch_and_update's abort channel as
  # `{:noop, user}` so the idempotent re-sync commits nothing — no UPDATE row,
  # no audit event.
  defp sync_full_name_changeset(%User{full_name: full_name} = user, full_name), do: {:noop, user}

  defp sync_full_name_changeset(%User{} = user, full_name),
    do: User.Changeset.profile(user, %{full_name: full_name})

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
