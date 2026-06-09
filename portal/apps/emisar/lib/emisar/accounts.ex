defmodule Emisar.Accounts do
  @moduledoc """
  The multi-tenant boundary. Manages accounts (orgs), users, and the
  memberships that join them with a role.

  Every read API in the rest of the system is expected to scope by
  account; this context owns the slug-based lookups and signup flow.
  """

  alias Ecto.Multi
  alias Emisar.{Audit, Auth, Repo, Slug}
  alias Emisar.Accounts.{Account, Authorizer, Membership, User, UserRunnerScope}
  alias Emisar.Auth.{Role, Subject}

  require Logger

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
  Accounts the subject's user is a (non-suspended) member of,
  name-ordered. Returns `{:ok, [account], %Paginator.Metadata{}}`. Drives
  the account picker.

  Deliberately **cross-account**: it lists every tenant the user belongs
  to, so it scopes by the subject's own actor id rather than running
  `Authorizer.for_subject/2` (which would narrow to a single account).
  The subject's user is the only authorization that applies — you can
  only ever list your own memberships.
  """
  def list_accounts_for_user(%Subject{actor: %User{id: user_id}}, opts \\ []) do
    Account.Query.not_deleted()
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
  transaction so a half-created account is impossible. Audit-logs both
  `user.signed_up` (the new user) and `account.created` (the new
  tenant) — together they form the "this person stood up a new team"
  trace operators need for billing/abuse review.
  """
  def create_account_with_owner(account_attrs, %User{} = user) do
    Multi.new()
    |> Multi.insert(:account, Account.Changeset.create(account_attrs))
    |> Multi.insert(:membership, fn %{account: account} ->
      Membership.Changeset.create(%{account_id: account.id, user_id: user.id, role: :owner})
    end)
    # Workspace gets the v2 conservative default policy on creation.
    # Without this, `Policies.evaluate(nil, ...)` would default-deny
    # every dispatch — which is correct but unhelpful as a first run.
    |> Multi.run(:policy, fn _repo, %{account: account} ->
      Emisar.Policies.seed_policy(account.id, user.id)
    end)
    |> Multi.insert(:account_created, fn %{account: account} ->
      Audit.Events.account_created(account, user)
    end)
    |> Multi.insert(:user_signed_up, fn %{account: account} ->
      Audit.Events.user_signed_up(user, account)
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{account: account}} -> {:ok, account}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Update an account's settings. The required permission is **field-aware**:
  changing a security setting (`require_mfa`) needs the owner-only
  `manage_security_settings` permission, while renaming/rebranding only
  needs `manage_own_account` (owner + admin). This stops an admin from
  turning OFF account-wide MFA enforcement — a security downgrade only an
  owner should make.

  When `require_mfa` is flipped on, every signed-in user without
  `mfa_enabled_at` is funneled to MFA setup by
  `EmisarWeb.UserAuth.on_mount(:ensure_mfa_compliant)` until they enroll
  (owners included). A security change is audited as `account.require_mfa_set`,
  everything else as `account.updated`.
  """
  def update_account(%Account{} = account, attrs, %Subject{} = subject) do
    changeset = Account.Changeset.update(account, attrs)

    with :ok <- ensure_account_changes_permitted(changeset, subject),
         :ok <- ensure_subject_owns_account(subject, account) do
      Multi.new()
      |> Multi.update(:account, changeset)
      |> Multi.insert(:audit, fn %{account: updated} ->
        account_update_audit(updated, changeset, subject)
      end)
      |> Repo.commit_multi()
      |> case do
        {:ok, %{account: updated}} -> {:ok, updated}
        {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
        {:error, other} -> {:error, other}
      end
    end
  end

  def change_account(%Account{} = account, attrs \\ %{}) do
    Account.Changeset.update(account, attrs)
  end

  # Field-aware authorization: a security-setting change requires the
  # owner-only permission on top of manage_own_account; a plain
  # rename/rebrand only needs manage_own_account.
  defp ensure_account_changes_permitted(%Ecto.Changeset{} = changeset, %Subject{} = subject) do
    required =
      if Map.has_key?(changeset.changes, :require_mfa) do
        [
          Authorizer.manage_own_account_permission(),
          Authorizer.manage_security_settings_permission()
        ]
      else
        [Authorizer.manage_own_account_permission()]
      end

    Auth.Authorizer.ensure_has_permissions(subject, required)
  end

  # A require_mfa change is a security event; everything else is a plain
  # account.updated. The UI never changes both in one request.
  defp account_update_audit(
         %Account{} = account,
         %Ecto.Changeset{} = changeset,
         %Subject{} = subject
       ) do
    if Map.has_key?(changeset.changes, :require_mfa) do
      Audit.Events.account_require_mfa_set(subject, account)
    else
      Audit.Events.account_updated(subject, account)
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
    base = Slug.slugify(name, max_length: 60, default: "team")
    do_suggest(base, 0)
  end

  defp do_suggest(base, n) do
    candidate = if n == 0, do: base, else: "#{base}-#{n}"

    case fetch_account_by_slug(candidate) do
      {:ok, _} -> do_suggest(base, n + 1)
      {:error, :not_found} -> candidate
    end
  end

  # -- Memberships ------------------------------------------------------

  @doc """
  Memberships of `account` (the team page). The subject must have access
  to the account — a member of it, or `:system`.

  Scopes by the **explicit** account id, not just `Authorizer.for_subject/2`:
  a `:system` subject bypasses that scoping, so a background fan-out (e.g.
  approval notifications) would otherwise list every account's members
  instead of this one's.
  """
  def list_memberships_for_account(%Account{id: account_id}, %Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_own_account_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, account_id, :unauthorized) do
      opts = Keyword.put_new(opts, :preload, [:account, :user])

      Membership.Query.not_deleted()
      |> Membership.Query.by_account_id(account_id)
      |> Authorizer.for_subject(subject)
      |> Repo.list(Membership.Query, opts)
    end
  end

  # Internal helper for permission checks that operate on nil-or-struct.
  defp peek_membership(account_id, user_id) do
    Membership.Query.not_deleted()
    |> Membership.Query.by_account_and_user(account_id, user_id)
    |> Repo.peek()
  end

  @doc """
  Resolve the membership to mount as the user's active tenant for this
  request. If `account_id` is given and the user has a non-suspended
  membership on that (non-deleted) account, return it. Otherwise fall
  back to the most recently-joined non-suspended membership — the
  default for first sign-in or after a stale session value is cleared.

  Returns `{:ok, membership} | {:error, :not_found}`. Pre-Subject —
  called from `UserAuth` before there's a Subject to authorize with.
  """
  def fetch_membership_for_session(%User{id: user_id}, account_id) do
    case maybe_fetch_session_membership(user_id, account_id) do
      {:ok, membership} ->
        {:ok, membership}

      {:error, :not_found} ->
        Membership.Query.not_deleted()
        |> Membership.Query.by_user_id(user_id)
        |> Membership.Query.not_disabled()
        |> Membership.Query.for_active_account()
        |> Membership.Query.latest()
        |> Repo.fetch(Membership.Query, preload: [:account, :user])
    end
  end

  defp maybe_fetch_session_membership(_user_id, nil), do: {:error, :not_found}

  defp maybe_fetch_session_membership(user_id, account_id) when is_binary(account_id) do
    if Repo.valid_uuid?(account_id) do
      Membership.Query.not_deleted()
      |> Membership.Query.by_account_and_user(account_id, user_id)
      |> Membership.Query.not_disabled()
      |> Membership.Query.for_active_account()
      |> Repo.fetch(Membership.Query, preload: [:account, :user])
    else
      {:error, :not_found}
    end
  end

  defp maybe_fetch_session_membership(_, _), do: {:error, :not_found}

  @doc """
  True if every membership the user holds is suspended (and they have
  at least one). Distinct from "user has no memberships" — the UI
  needs to show "your access was suspended" rather than send them to
  onboarding.
  """
  def all_memberships_suspended?(%User{id: user_id}) do
    base = Membership.Query.not_deleted() |> Membership.Query.by_user_id(user_id)
    Repo.exists?(base) and not Repo.exists?(Membership.Query.not_disabled(base))
  end

  # Internal write — the invite flow (already authorized via
  # invite_member_permission) is the only caller. Not a public API:
  # there's no Subject gate here, so it must never be reachable from
  # LiveView/controllers/MCP. Fixtures build memberships directly.
  defp create_membership(attrs) do
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
      Multi.new()
      |> Multi.update(:membership, Membership.Changeset.update(target, %{role: new_role}))
      |> Multi.insert(:audit, fn _ ->
        Audit.Events.membership_role_changed(subject, target, new_role)
      end)
      |> Repo.commit_multi(after_commit: &broadcast_team_change(&1, "membership.role_changed"))
      |> case do
        {:ok, %{membership: m}} -> {:ok, m}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp broadcast_team_change(%{membership: m}, event_type) do
    Emisar.PubSub.broadcast_account_list(m.account_id, :team, event_type, m.user_id)
    :ok
  end

  defp ensure_role_change_allowed(%Membership{} = target, new_role, %Subject{} = subject) do
    new_role = normalize_role(new_role)

    cond do
      # Self-promotion is never allowed (an admin cannot promote themselves
      # to owner; an operator cannot promote themselves to admin).
      target.user_id == subject.actor.id and target.role != new_role and
          Role.at_least?(new_role, target.role) ->
        {:error, :cannot_self_promote}

      # Only owners can grant the owner role.
      new_role == :owner and not can_manage_owners?(subject) ->
        {:error, :owner_required}

      # Only owners can take the owner role away from someone.
      target.role == :owner and not can_manage_owners?(subject) ->
        {:error, :owner_required}

      # Don't demote the last owner.
      target.role == :owner and new_role != :owner and
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

  Suspended memberships are skipped by `fetch_membership_for_session/2`
  so the user can't reach the product even if their session cookie is
  still valid; the `UserAuth` plug also kills the live session on detect.
  """
  def suspend_membership(%Membership{} = target, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_team_permission()),
         :ok <- ensure_subject_in_account(subject, target.account_id),
         :ok <- ensure_can_modify_membership(target, subject),
         :ok <- ensure_not_last_owner_change(target, "suspended") do
      Multi.new()
      |> Multi.update(:membership, Membership.Changeset.suspend(target))
      |> Multi.insert(:audit, fn _ ->
        Audit.Events.membership_suspended(subject, target)
      end)
      |> Repo.commit_multi(
        after_commit: [
          # Broadcast first so the team-page LV refreshes the row before
          # we kill the user's sessions — keeps the visual ordering sane.
          &broadcast_team_change(&1, "membership.suspended"),
          # Session kill is a side effect — broadcast PubSub disconnects
          # only after the suspension actually commits. Otherwise a rolled-
          # back update would still kick the user out of every tab.
          fn _ -> disconnect_user_sessions(target) end
        ]
      )
      |> case do
        {:ok, %{membership: m}} -> {:ok, m}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp disconnect_user_sessions(%Membership{} = membership) do
    case fetch_user_by_id(membership.user_id) do
      {:ok, user} ->
        Emisar.Auth.disconnect_and_revoke_all_sessions(user)
        :ok

      {:error, reason} ->
        Logger.warning("suspend_membership_user_missing",
          user_id: membership.user_id,
          membership_id: membership.id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  @doc "Re-enable a previously suspended member. Same authorization shape as suspend."
  def reinstate_membership(%Membership{} = target, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_team_permission()),
         :ok <- ensure_subject_in_account(subject, target.account_id),
         :ok <- ensure_can_modify_membership(target, subject) do
      Multi.new()
      |> Multi.update(:membership, Membership.Changeset.reinstate(target))
      |> Multi.insert(:audit, fn _ ->
        Audit.Events.membership_reinstated(subject, target)
      end)
      |> Repo.commit_multi(after_commit: &broadcast_team_change(&1, "membership.reinstated"))
      |> case do
        {:ok, %{membership: m}} -> {:ok, m}
        {:error, reason} -> {:error, reason}
      end
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
      # Null out password hash + audit atomically. `valid_password?/2`
      # guards on `is_binary(hashed_password)` — nil falls through to
      # the timing-safe placeholder branch and returns false, so the
      # old credential stops working the moment this commits.
      Multi.new()
      |> Multi.update(:user, Ecto.Changeset.change(user, %{hashed_password: nil}))
      |> Multi.insert(:audit, fn _ ->
        Audit.Events.user_password_reset_forced(subject, target, user)
      end)
      |> Repo.commit_multi(
        # Sending the reset email + broadcasting disconnects are side
        # effects that must NOT happen if the password-null update
        # rolled back. We pass `audit: false` to the token mint so it
        # doesn't ALSO emit a `user.password_reset_requested` row — that
        # row would attribute the action to the TARGET user as actor,
        # not the admin who triggered it. The `user.password_reset_forced`
        # event above is the canonical record of this action with the
        # correct actor → subject pair (admin → target).
        after_commit: fn %{user: user} ->
          :ok = Emisar.Auth.disconnect_and_revoke_all_sessions(user)
          token = Emisar.Auth.issue_password_reset_token!(user, audit: false)
          _ = Emisar.Mailers.UserNotifier.deliver_password_reset(user, token)
          :ok
        end
      )
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Admin-triggered profile edit for another member. Lets owners/admins
  set or fix a teammate's display name from the team page without
  making the teammate sign in to do it themselves.

  **Deliberately not allowed: email changes.** Letting an admin rewrite
  a teammate's sign-in email would be an account-takeover-as-feature
  (rewrite email → trigger password reset → read the link from the
  attacker's inbox). The teammate has to change their own email via
  Profile + current-password challenge. Same applies to password —
  that path is `force_password_reset/2`.

  Same authorization shape as the rest of `ensure_can_modify_membership`:
  caller must be owner/admin, can't edit self via this path (use
  Profile), admins can't edit owners.

  Audit-logged as `user.updated_by_admin` so the change is traceable.
  """
  def update_user_as_admin(%Membership{} = target, attrs, %Subject{} = subject)
      when is_map(attrs) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_team_permission()),
         :ok <- ensure_subject_in_account(subject, target.account_id),
         :ok <- ensure_can_modify_membership(target, subject),
         {:ok, user} <- fetch_user_by_id(target.user_id) do
      # profile/2 casts full_name only — email/password are deliberately
      # not editable through the admin path (see moduledoc). The field
      # whitelist lives in the changeset, not here.
      Multi.new()
      |> Multi.update(:user, User.Changeset.profile(user, attrs))
      |> Multi.insert(:audit, fn %{user: updated} ->
        Audit.Events.user_updated_by_admin(subject, target, updated)
      end)
      |> Repo.commit_multi()
      |> case do
        {:ok, %{user: updated}} -> {:ok, updated}
        {:error, reason} -> {:error, reason}
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
      # The DB-side delete of session tokens is the source of truth — bundle
      # it with the audit row so we never end up with "tokens deleted but no
      # audit" or vice versa. The PubSub disconnect broadcast is a side
      # effect that fires only after the rows actually commit.
      Multi.new()
      |> Multi.delete_all(
        :tokens,
        Auth.UserToken.Query.by_user_id(user.id)
        |> Auth.UserToken.Query.by_contexts(["session"])
      )
      |> Multi.insert(:audit, fn _ ->
        Audit.Events.user_sessions_revoked(subject, target, user)
      end)
      |> Repo.commit_multi(
        after_commit: fn _ ->
          Emisar.Auth.broadcast_disconnect_for_user(user)
          :ok
        end
      )
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
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
    cond do
      target.user_id == subject.actor.id ->
        {:error, :cannot_modify_self}

      target.role == :owner and not can_manage_owners?(subject) ->
        {:error, :owner_required}

      true ->
        :ok
    end
  end

  defp ensure_not_last_owner_change(%Membership{role: :owner} = target, _action) do
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
      Multi.new()
      |> Multi.delete(:membership, target)
      |> Multi.insert(:audit, fn _ ->
        Audit.Events.membership_removed(subject, target)
      end)
      |> Repo.commit_multi(after_commit: &broadcast_team_change(&1, "membership.removed"))
      |> case do
        {:ok, %{membership: deleted}} -> {:ok, deleted}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp ensure_delete_membership_allowed(%Membership{} = target, %Subject{} = subject) do
    cond do
      target.role == :owner and not can_manage_owners?(subject) ->
        {:error, :owner_required}

      target.role == :owner and count_owners(target.account_id) <= 1 ->
        {:error, :last_owner}

      true ->
        :ok
    end
  end

  # Only ACTIVE owners count toward the "must have at least one"
  # invariant — a suspended owner can't sign in or act, so they don't
  # protect against the account losing its last working admin.
  defp count_owners(account_id) do
    Membership.Query.not_deleted()
    |> Membership.Query.by_account_id(account_id)
    |> Membership.Query.by_role(:owner)
    |> Membership.Query.not_disabled()
    |> Repo.aggregate(:count, :id)
  end

  # Owner-only capability, checked by permission rather than role name.
  defp can_manage_owners?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.manage_owners_permission())

  # Coerce a role name to a known atom for guard comparisons; nil for an
  # unrecognized value (which then falls through to the changeset, where
  # Ecto.Enum rejects it with "is invalid").
  defp normalize_role(role) do
    case Role.cast(role) do
      {:ok, role} -> role
      :error -> nil
    end
  end

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

            Audit.Events.user_invited(subject, user, role) |> Repo.insert()

            %{membership: membership, user: user, invitation_token: token, created?: created?}

          %Membership{} ->
            Repo.rollback(:already_member)
        end
      end)
    end
  end

  # An admin can invite anybody except an owner; only a subject holding
  # manage_owners (i.e. an owner) can mint an owner. Mirrors the
  # role-change guard so the two paths stay consistent.
  defp ensure_invite_role_allowed(role, %Subject{} = subject) do
    if normalize_role(role) == :owner and not can_manage_owners?(subject) do
      {:error, :owner_required}
    else
      :ok
    end
  end

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
    Membership.Query.not_deleted()
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

    Multi.new()
    |> Multi.update(
      :membership,
      Ecto.Changeset.change(membership, invitation_token: nil, invitation_accepted_at: now)
    )
    |> Multi.insert(:audit, fn _ ->
      Audit.Events.membership_invitation_accepted(membership)
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{membership: m}} -> {:ok, m}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Accepts a membership invitation: sets the user's full_name + password,
  clears the invitation token, marks invitation_accepted_at. Confirms
  the user since the invitation acceptance proves they own the email.

  Wrapped in a transaction so a half-accepted state is impossible.
  """
  def accept_invitation(%Membership{} = membership, %{} = user_attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Multi.new()
    |> Multi.run(:existing_user, fn _repo, _changes -> fetch_user_by_id(membership.user_id) end)
    |> Multi.update(:user, fn %{existing_user: existing_user} ->
      User.Changeset.registration(existing_user, user_attrs)
    end)
    |> Multi.update(:confirmed_user, fn %{user: u} -> User.Changeset.confirm(u) end)
    |> Multi.update(
      :membership,
      Ecto.Changeset.change(membership, invitation_token: nil, invitation_accepted_at: now)
    )
    |> Multi.insert(:audit, fn %{confirmed_user: user, membership: m} ->
      Audit.Events.user_invitation_accepted(user, m)
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{confirmed_user: user, membership: m}} -> {:ok, %{user: user, membership: m}}
      {:error, reason} -> {:error, reason}
    end
  end

  # -- Users ------------------------------------------------------------

  def fetch_user_by_id(id) do
    if Repo.valid_uuid?(id) do
      User.Query.not_deleted()
      |> User.Query.by_id(id)
      |> Repo.fetch(User.Query)
    else
      {:error, :not_found}
    end
  end

  def fetch_user_by_id!(id) do
    User.Query.not_deleted()
    |> User.Query.by_id(id)
    |> Repo.fetch!(User.Query)
  end

  def fetch_user_by_email(email) when is_binary(email) do
    User.Query.not_deleted()
    |> User.Query.by_email(email)
    |> Repo.fetch(User.Query)
  end

  # -- Per-user runner ACLs (per-membership scope) -----------------
  #
  # Empty scope list = all runners (default). Any rows = union of
  # (group, runner) tuples — a runner is in-scope when its id OR its
  # group matches at least one row.

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
  def replace_runner_scopes(
        %Membership{id: membership_id} = membership,
        new_scopes,
        %Subject{} = subject
      )
      when is_list(new_scopes) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_team_permission()),
         :ok <- ensure_subject_in_account(subject, membership.account_id) do
      multi =
        Multi.new()
        |> Multi.delete_all(:cleared, UserRunnerScope.Query.by_membership_id(membership_id))

      multi =
        Enum.reduce(Enum.with_index(new_scopes), multi, fn {{type, value}, i}, acc ->
          Multi.insert(
            acc,
            {:scope, i},
            UserRunnerScope.Changeset.create(membership_id, type, value)
          )
        end)

      multi
      |> Multi.insert(:audit, fn _ ->
        Audit.Events.membership_runner_scopes_changed(subject, membership, new_scopes)
      end)
      |> Repo.commit_multi()
      |> case do
        {:ok, _changes} -> {:ok, :ok}
        {:error, reason} -> {:error, reason}
      end
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
      %UserRunnerScope{scope_type: :runner, scope_value: ^id} -> true
      %UserRunnerScope{scope_type: :group, scope_value: ^group} -> true
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
        User.Query.not_deleted()
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
  Update the caller's own profile fields. Self-service — the user is the
  subject's own actor; admins use `update_user_as_admin/3` for teammates.
  """
  def update_user_profile(attrs, %Subject{actor: %User{} = user}) do
    Multi.new()
    |> Multi.update(:user, User.Changeset.profile(user, attrs))
    |> Audit.Multi.log_for_user(:audit, user, "user.profile_updated",
      payload_fn: fn %{user: updated} -> %{full_name: updated.full_name} end
    )
    |> Repo.commit_multi()
    |> case do
      {:ok, %{user: updated}} -> {:ok, updated}
      {:error, reason} -> {:error, reason}
    end
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
  def update_user_email(new_email, current_password, %Subject{actor: %User{} = user})
      when is_binary(new_email) and is_binary(current_password) do
    if User.valid_password?(user, current_password) do
      Multi.new()
      |> Multi.update(:user, User.Changeset.email(user, %{email: new_email}))
      |> Audit.Multi.log_for_user(:audit, user, "user.email_changed",
        payload_fn: fn %{user: updated} -> %{from: user.email, to: updated.email} end
      )
      |> Repo.commit_multi()
      |> case do
        {:ok, %{user: updated}} -> {:ok, updated}
        {:error, reason} -> {:error, reason}
      end
    else
      # Failed-credential probe — audit it standalone since there's no
      # parent mutation to bundle with.
      Audit.log_for_user(user, "user.email_change_failed",
        payload: %{reason: "invalid_current_password"}
      )

      {:error, :invalid_current_password}
    end
  end

  @doc """
  Change the caller's own sign-in password after verifying the current
  one. Returns `{:ok, user} | {:error, :invalid_current_password}
  | {:error, :passwords_must_match} | {:error, :password_too_short}
  | {:error, %Ecto.Changeset{}}`.

  Audits success (`user.password_changed`) and audit-records bad
  current-password attempts (`user.password_change_failed`) — wrong
  current-password on this form is a real-credential probe worth seeing.

  The caller is responsible for revoking other sessions after success —
  a successful password change implies "the old credential is blown",
  so every other device should sign out. Self-service — the user is the
  subject's own actor.
  """
  @password_min_length 12

  def change_user_password(current_password, new_password, %Subject{actor: %User{} = user})
      when is_binary(current_password) and is_binary(new_password) do
    with :ok <- ensure_password_length(new_password),
         :ok <- ensure_current_password(user, current_password) do
      Multi.new()
      |> Multi.update(:user, User.Changeset.password(user, %{password: new_password}))
      |> Audit.Multi.log_for_user(:audit, user, "user.password_changed")
      |> Repo.commit_multi()
      |> case do
        {:ok, %{user: updated}} -> {:ok, updated}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp ensure_password_length(p) when byte_size(p) >= @password_min_length, do: :ok
  defp ensure_password_length(_), do: {:error, :password_too_short}

  defp ensure_current_password(%User{} = user, current) do
    if User.valid_password?(user, current) do
      :ok
    else
      # Pre-mutation probe — no parent transaction to bundle with.
      Audit.log_for_user(user, "user.password_change_failed",
        payload: %{reason: "invalid_current_password"}
      )

      {:error, :invalid_current_password}
    end
  end

  def confirm_user(%User{} = user) do
    user |> User.Changeset.confirm() |> Repo.update()
  end

  def record_sign_in(%User{} = user) do
    user |> User.Changeset.sign_in() |> Repo.update()
  end

  def change_user(%User{} = user, attrs \\ %{}) do
    User.Changeset.registration(user, attrs, hash_password: false)
  end

  @doc """
  Validation-only changeset for the change-password form, so the profile
  LiveView can drive `phx-change` and render the length + confirmation-
  mismatch errors inline on the right fields. `hash_password: false`
  keeps it pure — no bcrypt on every keystroke and no `:password` change
  consumed, so the field round-trips for redisplay. The actual change
  (with the current-password challenge + audit) is `change_user_password/4`.
  """
  def change_user_password_form(%User{} = user, attrs \\ %{}) do
    User.Changeset.password(user, attrs, hash_password: false)
  end
end
