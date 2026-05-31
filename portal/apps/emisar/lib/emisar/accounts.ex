defmodule Emisar.Accounts do
  @moduledoc """
  The multi-tenant boundary. Manages accounts (orgs), users, and the
  memberships that join them with a role.

  Every read API in the rest of the system is expected to scope by
  account; this context owns the slug-based lookups and signup flow.
  """

  alias Emisar.{Auth, Repo}
  alias Emisar.Accounts.{Account, Authorizer, Membership, User}
  alias Emisar.Auth.Subject

  # -- Accounts ---------------------------------------------------------

  # Account lookups by id / slug are pre-authentication — they're how
  # `UserAuth.assign_current_account` and the public `/onboarding` path
  # resolve an account before there's a Subject to authorize with.
  # They intentionally don't take a Subject; callers operating in an
  # authenticated context should prefer `socket.assigns.current_account`
  # over re-fetching.

  def fetch_account_by_id(id) do
    if Repo.valid_uuid?(id) do
      Account.Query.not_deleted()
      |> Account.Query.by_id(id)
      |> Repo.fetch(Account.Query)
    else
      {:error, :not_found}
    end
  end

  def fetch_account_by_id!(id) do
    Account.Query.not_deleted()
    |> Account.Query.by_id(id)
    |> Repo.fetch!(Account.Query)
  end

  def fetch_account_by_slug(slug) when is_binary(slug) do
    Account.Query.not_deleted()
    |> Account.Query.by_slug(slug)
    |> Repo.fetch(Account.Query)
  end

  @doc """
  Accounts the user is a (non-suspended) member of, name-ordered.
  Returns `{:ok, [account], %Paginator.Metadata{}}` per the context-
  function convention. Pre-Subject lookup — called from the account
  picker before a Subject exists (the user just signed in and the
  picker decides which tenant to mount).
  """
  def list_accounts_for_user(%User{id: user_id}, opts \\ []) do
    Account.Query.not_deleted()
    |> Account.Query.not_disabled()
    |> Account.Query.with_active_member(user_id)
    |> Account.Query.ordered_by_name()
    |> Repo.list(Account.Query, opts)
  end

  def create_account(attrs) do
    Account.Changeset.create(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates an account with the given user as `:owner`. Wrapped in a
  transaction so a half-created account is impossible.
  """
  def create_account_with_owner(account_attrs, %User{} = user) do
    Repo.transaction(fn ->
      with {:ok, account} <- create_account(account_attrs),
           {:ok, _membership} <-
             create_membership(%{account_id: account.id, user_id: user.id, role: "owner"}),
           {:ok, _policy} <- seed_default_policy(account.id, user.id) do
        account
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  # Workspace gets the v2 conservative default policy on creation.
  # Without this, `Policies.evaluate(nil, ...)` would default-deny
  # every dispatch — which is correct but unhelpful as a first run.
  defp seed_default_policy(account_id, user_id) do
    Emisar.Policies.seed_policy(account_id, user_id)
  end

  def update_account(%Account{} = account, attrs, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_own_account_permission()
           ),
         :ok <- ensure_subject_owns_account(subject, account) do
      account
      |> Account.Changeset.update(attrs)
      |> Repo.update()
    end
  end

  def change_account(%Account{} = account, attrs \\ %{}) do
    Account.Changeset.update(account, attrs)
  end

  @doc """
  Owner-only toggle for account-wide MFA enforcement. When flipped on,
  every signed-in user without `mfa_enabled_at` is funneled to the
  profile MFA-setup page by `EmisarWeb.UserAuth.on_mount(:ensure_mfa_compliant)`
  until they enroll. Owners are explicitly NOT exempt — if you're the
  one turning this on, you've already enrolled yourself (the UI gates
  the toggle behind that). Audited as `account.require_mfa_set`.
  """
  def update_account_require_mfa(%Account{} = account, value, %Subject{} = subject)
      when is_boolean(value) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_security_settings_permission()
           ),
         :ok <- ensure_subject_owns_account(subject, account) do
      result =
        account
        |> Account.Changeset.update_security(%{require_mfa: value})
        |> Repo.update()

      with {:ok, updated} <- result do
        Emisar.Audit.log(account.id, "account.require_mfa_set",
          actor_kind: "user",
          actor_id: subject.actor.id,
          subject_kind: "account",
          subject_id: account.id,
          payload: %{require_mfa: value}
        )

        {:ok, updated}
      end
    end
  end

  # Confirms the subject and account align — defense in depth on top of
  # the role-based permission check. Without this, an admin in account A
  # could (in theory) call `update_account` against an account B struct
  # they happened to obtain — the permission check passes but the wrong
  # row would be touched.
  defp ensure_subject_owns_account(%Subject{} = subject, %Account{id: id}),
    do: Subject.ensure_in_account(subject, id, :unauthorized)

  @doc """
  Suggests a unique slug for `name`. If the slugified name is taken,
  appends `-1`, `-2`, … until free.
  """
  def suggest_unique_slug(name) do
    base = slugify(name)
    do_suggest(base, 0)
  end

  defp do_suggest(base, n) do
    candidate = if n == 0, do: base, else: "#{base}-#{n}"

    case fetch_account_by_slug(candidate) do
      {:ok, _} -> do_suggest(base, n + 1)
      {:error, :not_found} -> candidate
    end
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "team"
      s -> String.slice(s, 0, 60)
    end
  end

  # -- Memberships ------------------------------------------------------

  def list_memberships_for_account(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_own_account_permission()
           ) do
      Membership.Query.all()
      |> Authorizer.for_subject(subject)
      |> Repo.list(Membership.Query, Keyword.put_new(opts, :preload, [:account, :user]))
    end
  end

  @doc """
  Internal cross-context lookup by (account_id, user_id). Used by
  fixtures and accounts_test to inspect post-mutation state; no
  Subject because both ids are opaque references the caller has
  already proven access to.
  """
  def fetch_membership_by_account_and_user(account_id, user_id) do
    Membership.Query.all()
    |> Membership.Query.by_account_and_user(account_id, user_id)
    |> Repo.fetch(Membership.Query)
  end

  # Internal helper for permission checks that operate on nil-or-struct.
  defp peek_membership(account_id, user_id) do
    Membership.Query.all()
    |> Membership.Query.by_account_and_user(account_id, user_id)
    |> Repo.peek()
  end

  @doc """
  The user's "current" account context for the UI. v0.1 just picks the
  most recently-joined non-disabled membership; later we can persist a
  preferred account in the user's profile.

  Pre-Subject lookup — called from `UserAuth.mount_current_account`
  to decide which tenant Subject to construct in the first place.
  Returns `{:ok, membership} | {:error, :not_found}`.
  """
  def fetch_primary_membership_for_user(%User{id: user_id}) do
    Membership.Query.all()
    |> Membership.Query.by_user_id(user_id)
    |> Membership.Query.not_disabled()
    |> Membership.Query.for_active_account()
    |> Membership.Query.ordered_by_recent()
    |> Membership.Query.latest()
    |> Repo.fetch(Membership.Query, preload: [:account, :user])
  end

  @doc """
  True iff every membership the user holds is suspended (and they have
  at least one). Distinct from "user has no memberships" — the UI
  needs to show "your access was suspended" rather than send them to
  onboarding.
  """
  def all_memberships_suspended?(%User{id: user_id}) do
    base = Membership.Query.all() |> Membership.Query.by_user_id(user_id)
    total = Repo.aggregate(base, :count, :id)
    total > 0 and Repo.aggregate(Membership.Query.not_disabled(base), :count, :id) == 0
  end

  def create_membership(attrs) do
    Membership.Changeset.create(attrs)
    |> Repo.insert()
  end

  @doc """
  Update a membership's role with hierarchy invariants.

  Returns `{:error, :unauthorized}` for forbidden transitions:
    * Only owners can grant or revoke owner.
    * Admins cannot modify owners.
    * Nobody can promote themselves.
    * Nobody can demote/remove the last owner.

  The caller passes their `%Subject{}` so the guard runs at the domain
  boundary, not just in LiveView templates.
  """
  def update_membership_role(%Membership{} = target, new_role, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_team_permission()),
         :ok <- ensure_subject_in_account(subject, target.account_id),
         :ok <- ensure_role_change_allowed(target, new_role, subject) do
      target |> Membership.Changeset.update(%{role: new_role}) |> Repo.update()
    end
  end

  defp ensure_role_change_allowed(%Membership{} = target, new_role, %Subject{} = subject) do
    actor_user_id = subject.actor.id
    actor_role = subject.role

    cond do
      # Self-promotion is never allowed (an admin cannot promote themselves
      # to owner; an operator cannot promote themselves to admin).
      target.user_id == actor_user_id and target.role != new_role and
          role_rank(new_role) < role_rank(target.role) ->
        {:error, :cannot_self_promote}

      # Only owners can grant the owner role.
      new_role == "owner" and actor_role != :owner ->
        {:error, :owner_required}

      # Only owners can take the owner role away from someone.
      target.role == "owner" and actor_role != :owner ->
        {:error, :owner_required}

      # Don't demote the last owner.
      target.role == "owner" and new_role != "owner" and
          count_owners(target.account_id) <= 1 ->
        {:error, :last_owner}

      true ->
        :ok
    end
  end

  @doc """
  Suspend a member's access to this account. The membership row stays
  (so role + history are preserved for an eventual reinstate). Same
  authorization shape as role/remove changes:

    * Only owners can suspend other owners.
    * Admins/owners can suspend non-owners.
    * The last owner cannot be suspended.
    * Operator/viewer can't call this at all.

  Suspended memberships are skipped by `fetch_primary_membership_for_user/1`
  so the user can't reach the product even if their session cookie is
  still valid; the `UserAuth` plug also kills the live session on detect.
  """
  def suspend_membership(%Membership{} = target, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_team_permission()),
         :ok <- ensure_subject_in_account(subject, target.account_id),
         :ok <- ensure_can_modify_membership(target, subject),
         :ok <- ensure_not_last_owner_change(target, "suspended"),
         {:ok, updated} <- target |> Membership.Changeset.suspend() |> Repo.update() do
      # Kill every active session for the suspended user so they can't
      # keep using the product on an open tab. If the user lookup fails
      # the membership row is orphaned — log loudly so the operator can
      # investigate; the suspend itself is already committed.
      case fetch_user_by_id(target.user_id) do
        {:ok, user} ->
          Emisar.Auth.delete_all_session_tokens(user)

        {:error, reason} ->
          require Logger

          Logger.warning("suspend_membership_user_missing",
            user_id: target.user_id,
            membership_id: target.id,
            reason: inspect(reason)
          )
      end

      Emisar.Audit.log(target.account_id, "membership.suspended",
        actor_kind: "user",
        actor_id: subject.actor.id,
        subject_kind: "user",
        subject_id: target.user_id
      )

      {:ok, updated}
    end
  end

  @doc "Re-enable a previously suspended member. Same authorization shape as suspend."
  def reinstate_membership(%Membership{} = target, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_team_permission()),
         :ok <- ensure_subject_in_account(subject, target.account_id),
         :ok <- ensure_can_modify_membership(target, subject),
         {:ok, updated} <- target |> Membership.Changeset.reinstate() |> Repo.update() do
      Emisar.Audit.log(target.account_id, "membership.reinstated",
        actor_kind: "user",
        actor_id: subject.actor.id,
        subject_kind: "user",
        subject_id: target.user_id
      )

      {:ok, updated}
    end
  end

  @doc """
  Admin-triggered password reset: invalidates every active session for
  the target user, mints a reset-password token, and emails it. Same
  authorization shape as membership changes — the admin must be in
  the target's account and outrank them. Audit-logged.

  Note: the reset email is sent inside the call (mailer dispatch can
  block ~1s on SMTP) — fine for the team page button, but if it ever
  needs to be high-throughput, move to an Oban job.
  """
  def force_password_reset(%Membership{} = target, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_team_permission()),
         :ok <- ensure_subject_in_account(subject, target.account_id),
         :ok <- ensure_can_modify_membership(target, subject),
         {:ok, user} <- fetch_user_by_id(target.user_id) do
      # Drop all live sessions AND null out the existing password hash
      # so the old credential stops working immediately, not whenever
      # the user happens to click the email link. `valid_password?/2`
      # guards on `is_binary(hashed_password)` — nil falls through to
      # the timing-safe placeholder branch and returns false.
      :ok = Emisar.Auth.delete_all_session_tokens(user)

      {:ok, _user} =
        user
        |> Ecto.Changeset.change(%{hashed_password: nil})
        |> Repo.update()

      token = Emisar.Auth.issue_password_reset_token!(user)
      _ = Emisar.Mailers.UserNotifier.deliver_password_reset(user, token)

      Emisar.Audit.log(target.account_id, "user.password_reset_forced",
        actor_kind: "user",
        actor_id: subject.actor.id,
        subject_kind: "user",
        subject_id: user.id,
        subject_label: user.email
      )

      :ok
    end
  end

  @doc """
  Admin-triggered profile edit for another member. Lets owners/admins
  fix a teammate's typoed email or set their display name from the
  team page, without making the teammate sign in to do it themselves.

  Same authorization shape as the rest of `ensure_can_modify_membership`:
  caller must be owner/admin, can't edit self via this path (use Profile),
  admins can't edit owners.

  Audit-logged as `user.updated_by_admin` so the change is traceable.
  """
  def update_user_as_admin(%Membership{} = target, attrs, %Subject{} = subject)
      when is_map(attrs) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_team_permission()),
         :ok <- ensure_subject_in_account(subject, target.account_id),
         :ok <- ensure_can_modify_membership(target, subject),
         {:ok, user} <- fetch_user_by_id(target.user_id) do
      # Whitelist the fields admins are allowed to overwrite on a
      # teammate. No password reset here — that path is
      # `force_password_reset/2` and emails the user a magic link
      # instead of letting the admin pick the password.
      whitelisted =
        attrs
        |> Map.new(fn {k, v} -> {to_string(k), v} end)
        |> Map.take(["full_name", "email"])

      changeset =
        user
        |> User.Changeset.registration(whitelisted, hash_password: false)

      case Repo.update(changeset) do
        {:ok, updated} ->
          Emisar.Audit.log(target.account_id, "user.updated_by_admin",
            actor_kind: "user",
            actor_id: subject.actor.id,
            subject_kind: "user",
            subject_id: updated.id,
            subject_label: updated.email,
            payload: %{
              full_name: updated.full_name,
              email: updated.email
            }
          )

          {:ok, updated}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Admin-triggered "sign out everywhere" for a member. Kills every
  session on the user record. Audit-logged. Same authorization as
  membership changes.
  """
  def end_all_sessions_for(%Membership{} = target, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_team_permission()),
         :ok <- ensure_subject_in_account(subject, target.account_id),
         :ok <- ensure_can_modify_membership(target, subject),
         {:ok, user} <- fetch_user_by_id(target.user_id) do
      :ok = Emisar.Auth.delete_all_session_tokens(user)

      Emisar.Audit.log(target.account_id, "user.sessions_revoked",
        actor_kind: "user",
        actor_id: subject.actor.id,
        subject_kind: "user",
        subject_id: user.id,
        subject_label: user.email
      )

      :ok
    end
  end

  # Same-account check on top of the permission gate. The Authorizer's
  # `for_subject/2` does this for queryable reads; for direct-struct
  # mutations we need an explicit guard.
  defp ensure_subject_in_account(%Subject{} = subject, account_id),
    do: Subject.ensure_in_account(subject, account_id, :unauthorized)

  # Self-protection + owner-protection invariants that apply on top of
  # the role-permission check. The permission tells us the caller has
  # the right to manage_team in general; this enforces "can't shoot
  # yourself in the foot" and "can't pin owners around if you're not one".
  defp ensure_can_modify_membership(%Membership{} = target, %Subject{} = subject) do
    actor_user_id = subject.actor.id

    cond do
      target.user_id == actor_user_id ->
        {:error, :cannot_modify_self}

      target.role == "owner" and subject.role != :owner ->
        {:error, :owner_required}

      true ->
        :ok
    end
  end

  defp ensure_not_last_owner_change(%Membership{role: "owner"} = target, _action) do
    if count_owners(target.account_id) <= 1 do
      {:error, :last_owner}
    else
      :ok
    end
  end

  defp ensure_not_last_owner_change(%Membership{}, _), do: :ok

  @doc """
  Remove a membership, enforcing the same invariants as role updates:

    * Only owners can remove owners.
    * Admins/owners can remove non-owners; nobody can remove themselves
      while they are the last owner.
    * The last owner cannot be removed at all.
  """
  def delete_membership(%Membership{} = target, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_team_permission()),
         :ok <- ensure_subject_in_account(subject, target.account_id),
         :ok <- ensure_delete_membership_allowed(target, subject) do
      Repo.delete(target)
    end
  end

  defp ensure_delete_membership_allowed(%Membership{} = target, %Subject{} = subject) do
    cond do
      target.role == "owner" and subject.role != :owner ->
        {:error, :owner_required}

      target.role == "owner" and count_owners(target.account_id) <= 1 ->
        {:error, :last_owner}

      true ->
        :ok
    end
  end

  # Only ACTIVE owners count toward the "must have at least one"
  # invariant — a suspended owner can't sign in or act, so they don't
  # protect against the account losing its last working admin.
  defp count_owners(account_id) do
    Membership.Query.all()
    |> Membership.Query.by_account_id(account_id)
    |> Membership.Query.by_role("owner")
    |> Membership.Query.not_disabled()
    |> Repo.aggregate(:count, :id)
  end

  defp role_rank("owner"), do: 0
  defp role_rank("admin"), do: 1
  defp role_rank("operator"), do: 2
  defp role_rank("viewer"), do: 3
  defp role_rank(_), do: 99

  @doc """
  Invites a user (by email) into the account with the given role.

  If no user with that email exists, a placeholder user is created
  (unconfirmed, no password) so we have something to hang the
  membership and invitation token off of. Returns
  `{:ok, %{membership: m, user: u, invitation_token: token, created?: bool}}`
  on success.

  The caller is responsible for sending the invitation email; this
  context only persists the records and mints the token.
  """
  def invite_user_to_account(email, role, %Subject{account: %Account{id: account_id}} = subject)
      when is_binary(email) and is_binary(role) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.invite_member_permission()),
         :ok <- ensure_invite_role_allowed(role, subject) do
      email = String.downcase(String.trim(email))
      token = invitation_token()
      invited_by_id = subject.actor.id

      Repo.transaction(fn ->
        {user, created?} =
          case fetch_user_by_email(email) do
            {:ok, u} ->
              {u, false}

            {:error, :not_found} ->
              {:ok, u} =
                %User{}
                |> User.Changeset.registration(%{email: email}, hash_password: false)
                |> Repo.insert()

              {u, true}
          end

        case peek_membership(account_id, user.id) do
          nil ->
            {:ok, membership} =
              create_membership(%{
                account_id: account_id,
                user_id: user.id,
                role: role,
                invited_by_id: invited_by_id,
                invitation_token: token
              })

            Emisar.Audit.log(account_id, "user.invited",
              actor_kind: "user",
              actor_id: invited_by_id,
              subject_kind: "user",
              subject_id: user.id,
              subject_label: email,
              payload: %{role: role}
            )

            %{membership: membership, user: user, invitation_token: token, created?: created?}

          %Membership{} ->
            Repo.rollback(:already_member)
        end
      end)
    end
  end

  # An admin can invite anybody except an owner; only an owner can mint
  # an owner. Mirrors the role-change guard so the two paths are
  # consistent.
  defp ensure_invite_role_allowed("owner", %Subject{role: :owner}), do: :ok
  defp ensure_invite_role_allowed("owner", _subject), do: {:error, :owner_required}
  defp ensure_invite_role_allowed(_role, _subject), do: :ok

  defp invitation_token do
    :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  end

  @doc """
  Looks up a pending membership by invitation token. Returns the
  membership with `:account` and `:user` preloaded, or `{:error, :not_found}`.
  Pre-Subject helper — used by the invitation-accept LV before the user
  has signed in / chosen an account.
  """
  def fetch_invitation_by_token(token) when is_binary(token) and byte_size(token) > 0 do
    Membership.Query.all()
    |> Membership.Query.by_invitation_token(token)
    |> Membership.Query.pending_invitation()
    |> Repo.fetch(Membership.Query, preload: [:account, :user])
  end

  def fetch_invitation_by_token(_), do: {:error, :not_found}

  @doc """
  Marks an invitation accepted without touching the user record.
  Used when an already-signed-in user clicks an invite link for one of
  their own accounts — the user already has a password + confirmed_at,
  there's nothing to set, so we just clear the token + stamp
  `invitation_accepted_at`.
  """
  def mark_invitation_accepted(%Membership{} = membership) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    membership
    |> Ecto.Changeset.change(invitation_token: nil, invitation_accepted_at: now)
    |> Repo.update()
  end

  @doc """
  Accepts a membership invitation: sets the user's full_name + password,
  clears the invitation token, marks invitation_accepted_at. Confirms
  the user since the invitation acceptance proves they own the email.

  Wrapped in a transaction so a half-accepted state is impossible.
  """
  def accept_invitation(%Membership{} = membership, %{} = user_attrs) do
    Repo.transaction(fn ->
      with {:ok, user} <-
             fetch_user_by_id!(membership.user_id)
             |> User.Changeset.registration(user_attrs)
             |> Repo.update(),
           {:ok, user} <- confirm_user(user),
           {:ok, membership} <-
             membership
             |> Ecto.Changeset.change(
               invitation_token: nil,
               invitation_accepted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
             )
             |> Repo.update() do
        %{user: user, membership: membership}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # -- Users ------------------------------------------------------------

  def fetch_user_by_id(id) do
    if Repo.valid_uuid?(id) do
      User.Query.all()
      |> User.Query.by_id(id)
      |> Repo.fetch(User.Query)
    else
      {:error, :not_found}
    end
  end

  def fetch_user_by_id!(id) do
    User.Query.all()
    |> User.Query.by_id(id)
    |> Repo.fetch!(User.Query)
  end

  def fetch_user_by_email(email) when is_binary(email) do
    User.Query.all()
    |> User.Query.by_email(email)
    |> Repo.fetch(User.Query)
  end


  # -- Per-user runner ACLs (per-membership scope) -----------------
  #
  # Empty scope list = all runners (default). Any rows = union of
  # (group, runner) tuples — a runner is in-scope when its id OR its
  # group matches at least one row.

  alias Emisar.Accounts.UserRunnerScope

  @doc """
  All scope rows for a membership, ordered for stable rendering.

  Internal cross-context resolver — called from `Runners` /
  `Runs.dispatch_run` which have already authorized via Subject, and from
  the team-page LV which has the operator's own membership in scope.
  Tests use it to inspect post-mutation state. Does not take a Subject
  because the row scoping is by `membership_id` (an opaque identifier
  the caller has already proven access to).
  """
  def runner_scopes_for_membership(membership_id) when is_binary(membership_id) do
    UserRunnerScope.Query.by_membership_id(membership_id)
    |> UserRunnerScope.Query.ordered()
    |> Repo.all()
  end

  @doc """
  Replaces the scope set for a membership atomically. Pass a list of
  `{scope_type, scope_value}` tuples (or `[]` to clear → all-runners).
  Wrapped in a transaction so a partial failure can't leave a
  half-applied scope set.
  """
  def replace_runner_scopes(%Membership{id: membership_id} = membership, new_scopes, %Subject{} = subject)
      when is_list(new_scopes) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_team_permission()),
         :ok <- ensure_subject_in_account(subject, membership.account_id) do
      Repo.transaction(fn ->
        UserRunnerScope.Query.by_membership_id(membership_id)
        |> Repo.delete_all()

        Enum.each(new_scopes, fn {type, value} ->
          case UserRunnerScope.Changeset.create(membership_id, type, value)
               |> Repo.insert() do
            {:ok, _} -> :ok
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)

        :ok
      end)
    end
  end

  @doc """
  Batch resolver returning `%{membership_id => [%UserRunnerScope{}]}`
  so a list view can render scope chips without N+1 queries.
  """
  def runner_scopes_for_membership_ids(ids) when is_list(ids) do
    case Enum.reject(ids, &is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      ids ->
        UserRunnerScope.Query.by_membership_ids(ids)
        |> UserRunnerScope.Query.ordered()
        |> Repo.all()
        |> Enum.group_by(& &1.membership_id)
    end
  end

  @doc """
  True when the runner is visible/dispatchable for the membership.
  Empty scope = all runners. Otherwise the runner's id OR its group
  must appear in at least one row.

  `:system` actors and any membership with no scopes always pass.
  Pass `nil` membership for unauthenticated paths — returns true
  there too; callers must do their own auth check.
  """
  def runner_in_scope?(_runner, nil), do: true
  def runner_in_scope?(runner, %Membership{} = membership),
    do: runner_in_scope?(runner, runner_scopes_for_membership(membership.id))

  def runner_in_scope?(_runner, []), do: true

  def runner_in_scope?(%{id: id, group: group}, scopes) when is_list(scopes) do
    Enum.any?(scopes, fn
      %UserRunnerScope{scope_type: "runner", scope_value: ^id} -> true
      %UserRunnerScope{scope_type: "group", scope_value: ^group} -> true
      _ -> false
    end)
  end

  def runner_in_scope?(_runner, _scopes), do: false

  @doc """
  Batch resolver returning `%{user_id => display_name}` for the
  supplied ids. Falls back to email when full_name is blank.
  """
  def user_labels_for_ids(ids) when is_list(ids) do
    case Enum.reject(ids, &is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      ids ->
        User.Query.all()
        |> User.Query.by_ids(ids)
        |> Repo.all()
        |> Map.new(fn u -> {u.id, u.full_name || u.email} end)
    end
  end

  def register_user(attrs) do
    %User{}
    |> User.Changeset.registration(attrs)
    |> Repo.insert()
  end

  @doc """
  Update the caller's own profile fields. Subject must match the user
  being edited — admins use `update_user_as_admin/3` to edit teammates.
  """
  def update_user_profile(%User{} = user, attrs, %Subject{} = subject) do
    with :ok <- ensure_subject_is_user(subject, user) do
      user |> User.Changeset.profile(attrs) |> Repo.update()
    end
  end

  @doc """
  Change the user's sign-in email after verifying their current
  password. Returns `{:ok, user} | {:error, :invalid_current_password}
  | {:error, %Ecto.Changeset{}}`. Subject must match the user being
  edited — the current-password check is the proof-of-control gate.
  """
  def update_user_email(%User{} = user, new_email, current_password, %Subject{} = subject)
      when is_binary(new_email) and is_binary(current_password) do
    with :ok <- ensure_subject_is_user(subject, user) do
      if User.valid_password?(user, current_password) do
        user
        |> User.Changeset.email(%{email: new_email})
        |> Repo.update()
      else
        {:error, :invalid_current_password}
      end
    end
  end

  defp ensure_subject_is_user(%Subject{actor: :system}, %User{}), do: :ok

  defp ensure_subject_is_user(%Subject{actor: %User{id: id}}, %User{id: id}),
    do: :ok

  defp ensure_subject_is_user(_subject, _user), do: {:error, :unauthorized}

  def confirm_user(%User{} = user) do
    user |> User.Changeset.confirm() |> Repo.update()
  end

  def record_sign_in(%User{} = user) do
    user |> User.Changeset.sign_in() |> Repo.update()
  end

  def change_user(%User{} = user, attrs \\ %{}) do
    User.Changeset.registration(user, attrs, hash_password: false)
  end
end
