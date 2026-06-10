defmodule Emisar.Accounts do
  @moduledoc """
  The multi-tenant boundary. Manages accounts (orgs), users, and the
  memberships that join them with a role.

  Every read API in the rest of the system is expected to scope by
  account; this context owns the slug-based lookups and signup flow.
  """
  alias Ecto.Multi
  alias Emisar.{Audit, Auth, Crypto, Repo, Slug, Users}
  alias Emisar.Accounts.{Account, Authorizer, Membership}
  alias Emisar.Auth.{Role, Subject}
  alias Emisar.Users.User
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
    |> Account.Query.by_membership_user_id(user_id)
    |> Account.Query.ordered_by_name()
    |> Repo.list(Account.Query, opts)
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
        [
          Authorizer.manage_own_account_permission()
        ]
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

    taken? =
      Account.Query.not_deleted()
      |> Account.Query.by_slug(candidate)
      |> Repo.exists?()

    if taken?, do: do_suggest(base, n + 1), else: candidate
  end

  # -- Memberships ------------------------------------------------------

  @doc """
  Memberships of `account` (the team page). The subject must be a member
  of the account.

  Scopes by the **explicit** account id alongside `Authorizer.for_subject/2`
  (belt-and-suspenders: a wrong subject would otherwise scope to the wrong
  account). Background fan-outs that need every member use the no-subject
  `list_account_memberships/2` instead.
  """
  def list_memberships_for_account(%Account{id: account_id}, %Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_own_account_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, account_id, :unauthorized) do
      Membership.Query.not_deleted()
      |> Membership.Query.by_account_id(account_id)
      |> Authorizer.for_subject(subject)
      |> Membership.Query.with_preloaded_account()
      |> Membership.Query.with_preloaded_user()
      |> Repo.list(Membership.Query, opts)
    end
  end

  @doc """
  Internal: account-scoped membership page for system fan-outs (the approval
  notifier, which emails every approver). No `%Subject{}` — the caller is a
  background job already scoped to this account; pages via `opts` like the
  public `list_memberships_for_account/3`.
  """
  def list_account_memberships(account_id, opts \\ []) do
    Membership.Query.not_deleted()
    |> Membership.Query.by_account_id(account_id)
    |> Membership.Query.with_preloaded_account()
    |> Membership.Query.with_preloaded_user()
    |> Repo.list(Membership.Query, opts)
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
        |> Membership.Query.with_preloaded_account()
        |> Membership.Query.with_preloaded_user()
        |> Membership.Query.latest()
        |> Repo.fetch(Membership.Query)
    end
  end

  defp maybe_fetch_session_membership(user_id, account_id) do
    if Repo.valid_uuid?(account_id) do
      Membership.Query.not_deleted()
      |> Membership.Query.by_account_and_user(account_id, user_id)
      |> Membership.Query.not_disabled()
      |> Membership.Query.with_preloaded_account()
      |> Membership.Query.with_preloaded_user()
      |> Repo.fetch(Membership.Query)
    else
      {:error, :not_found}
    end
  end

  @doc """
  Audit a session account switch. The switch itself is web session state
  (no rows change), but the audit trail of it is the domain's record —
  controllers never write audit rows. Takes the membership resolved by
  `fetch_membership_for_session/2` (`:user` preloaded).
  """
  def record_account_switched(%Membership{} = membership) do
    membership |> Audit.Events.session_account_switched() |> Repo.insert()
  end

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
  def update_membership_role(%Membership{} = membership, new_role, %Subject{} = subject) do
    # The changeset's Ecto.Enum cast turns the submitted role name into its
    # atom (or marks the changeset invalid); read it back so the guards
    # below compare cast atoms — no hand-rolled role coercion here.
    changeset = Membership.Changeset.update(membership, %{role: new_role})
    new_role = Ecto.Changeset.get_field(changeset, :role)

    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_team_permission()),
         :ok <- ensure_subject_in_account(subject, membership.account_id),
         :ok <- ensure_role_change_allowed(membership, new_role, subject) do
      Multi.new()
      |> Multi.update(:membership, changeset)
      |> Multi.insert(:audit, fn _ ->
        Audit.Events.membership_role_changed(subject, membership, new_role)
      end)
      |> Repo.commit_multi(after_commit: &broadcast_team_change(&1, "membership.role_changed"))
      |> case do
        {:ok, %{membership: membership}} -> {:ok, membership}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp broadcast_team_change(%{membership: membership}, event_type) do
    Emisar.PubSub.broadcast_account_list(
      membership.account_id,
      :team,
      event_type,
      membership.user_id
    )

    :ok
  end

  defp ensure_role_change_allowed(%Membership{} = membership, new_role, %Subject{} = subject) do
    cond do
      # Can't grant a role whose permissions you don't already hold (no
      # escalation by proxy). On your own membership that's self-promotion.
      not Auth.Authorizer.covers_role?(subject, new_role) ->
        if membership.user_id == subject.actor.id,
          do: {:error, :cannot_self_promote},
          else: {:error, :insufficient_privileges}

      # Can't change the role of someone whose permissions outrank yours.
      not Auth.Authorizer.covers_role?(subject, membership.role) ->
        {:error, :insufficient_privileges}

      # Don't demote the last owner.
      membership.role == :owner and new_role != :owner and
          count_owners(membership.account_id) <= 1 ->
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
  def suspend_membership(%Membership{} = membership, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_team_permission()),
         :ok <- ensure_subject_in_account(subject, membership.account_id),
         :ok <- ensure_can_modify_membership(membership, subject),
         :ok <- ensure_not_last_owner_change(membership) do
      Multi.new()
      |> Multi.update(:membership, Membership.Changeset.suspend(membership))
      |> Multi.insert(:audit, fn _ ->
        Audit.Events.membership_suspended(subject, membership)
      end)
      |> Repo.commit_multi(
        after_commit: [
          # Broadcast first so the team-page LV refreshes the row before
          # we kill the user's sessions — keeps the visual ordering sane.
          &broadcast_team_change(&1, "membership.suspended"),
          # Session kill is a side effect — broadcast PubSub disconnects
          # only after the suspension actually commits. Otherwise a rolled-
          # back update would still kick the user out of every tab.
          fn _ -> disconnect_user_sessions(membership) end
        ]
      )
      |> case do
        {:ok, %{membership: membership}} -> {:ok, membership}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp disconnect_user_sessions(%Membership{} = membership) do
    case Users.fetch_user_by_id(membership.user_id) do
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
  def reinstate_membership(%Membership{} = membership, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_team_permission()),
         :ok <- ensure_subject_in_account(subject, membership.account_id),
         :ok <- ensure_can_modify_membership(membership, subject) do
      Multi.new()
      |> Multi.update(:membership, Membership.Changeset.reinstate(membership))
      |> Multi.insert(:audit, fn _ ->
        Audit.Events.membership_reinstated(subject, membership)
      end)
      |> Repo.commit_multi(after_commit: &broadcast_team_change(&1, "membership.reinstated"))
      |> case do
        {:ok, %{membership: membership}} -> {:ok, membership}
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
  def force_password_reset(%Membership{} = membership, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_team_permission()),
         :ok <- ensure_subject_in_account(subject, membership.account_id),
         :ok <- ensure_can_modify_membership(membership, subject) do
      # Users nulls the hash + inserts our audit atomically under the row
      # lock; the old credential stops working the moment this commits.
      #
      # Sending the reset email + broadcasting disconnects are side
      # effects that must NOT happen if the password-null update rolled
      # back. We pass `audit: false` to the token mint so it doesn't
      # ALSO emit a `user.password_reset_requested` row — that row would
      # attribute the action to the TARGET user as actor, not the admin
      # who triggered it. The `user.password_reset_forced` event below is
      # the canonical record with the correct actor → subject pair.
      Users.clear_user_password(membership.user_id,
        audit: fn updated ->
          Audit.Events.user_password_reset_forced(subject, membership, updated)
        end,
        after_commit: fn user ->
          :ok = Emisar.Auth.disconnect_and_revoke_all_sessions(user)
          token = Emisar.Auth.issue_password_reset_token!(user, audit: false)
          _ = Emisar.Mailers.UserNotifier.deliver_password_reset(user, token)
          :ok
        end
      )
      |> case do
        {:ok, _user} -> :ok
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
  def update_user_as_admin(%Membership{} = membership, attrs, %Subject{} = subject)
      when is_map(attrs) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_team_permission()),
         :ok <- ensure_subject_in_account(subject, membership.account_id),
         :ok <- ensure_can_modify_membership(membership, subject) do
      # Users whitelists the editable fields (full_name only — email and
      # password are deliberately not admin-editable, see moduledoc) and
      # holds the row lock while it writes + inserts our audit.
      Users.update_user_profile_as_admin(membership.user_id, attrs,
        audit: fn updated ->
          Audit.Events.user_updated_by_admin(subject, membership, updated)
        end
      )
    end
  end

  @doc """
  Admin-triggered "sign out everywhere" for a member. Kills every
  session on the user record. Audit-logged. Same authorization as
  membership changes.
  """
  def end_all_sessions_for(%Membership{} = membership, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_team_permission()),
         :ok <- ensure_subject_in_account(subject, membership.account_id),
         :ok <- ensure_can_modify_membership(membership, subject) do
      # The DB-side delete of session tokens is the source of truth — bundle
      # it with the audit row so we never end up with "tokens deleted but no
      # audit" or vice versa. The user read lives INSIDE the transaction so
      # it shares the snapshot with the delete (which Auth owns — token
      # internals stay private to it). The PubSub disconnect broadcast is a
      # side effect that fires only after the rows commit.
      Multi.new()
      |> Multi.run(:user, fn _repo, _changes -> Users.fetch_user_by_id(membership.user_id) end)
      |> Multi.run(:tokens, fn _repo, %{user: user} ->
        Emisar.Auth.delete_all_session_tokens(user)
      end)
      |> Multi.insert(:audit, fn %{user: user} ->
        Audit.Events.user_sessions_revoked(subject, membership, user)
      end)
      |> Repo.commit_multi(
        after_commit: fn %{user: user} ->
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

  # Invariants on top of the manage_team permission gate: you can't modify
  # your own membership (no shooting yourself in the foot), and you can't
  # touch a member whose role grants permissions you don't hold (can't pin
  # around a superior).
  defp ensure_can_modify_membership(%Membership{} = membership, %Subject{} = subject) do
    cond do
      membership.user_id == subject.actor.id ->
        {:error, :cannot_modify_self}

      not Auth.Authorizer.covers_role?(subject, membership.role) ->
        {:error, :insufficient_privileges}

      true ->
        :ok
    end
  end

  defp ensure_not_last_owner_change(%Membership{role: :owner} = membership) do
    if count_owners(membership.account_id) <= 1 do
      {:error, :last_owner}
    else
      :ok
    end
  end

  defp ensure_not_last_owner_change(%Membership{}), do: :ok

  @doc """
  Remove a membership, enforcing the same invariants as role updates:

    * You can only remove a member whose permissions you already hold, so a
      non-owner can't remove an owner.
    * The last active owner can't be removed (even by themselves).
  """
  def delete_membership(%Membership{} = membership, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_team_permission()),
         :ok <- ensure_subject_in_account(subject, membership.account_id),
         :ok <- ensure_delete_membership_allowed(membership, subject) do
      Multi.new()
      |> Multi.delete(:membership, membership)
      |> Multi.insert(:audit, fn _ ->
        Audit.Events.membership_removed(subject, membership)
      end)
      |> Repo.commit_multi(after_commit: &broadcast_team_change(&1, "membership.removed"))
      |> case do
        {:ok, %{membership: deleted}} -> {:ok, deleted}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp ensure_delete_membership_allowed(%Membership{} = membership, %Subject{} = subject) do
    cond do
      not Auth.Authorizer.covers_role?(subject, membership.role) ->
        {:error, :insufficient_privileges}

      membership.role == :owner and count_owners(membership.account_id) <= 1 ->
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

  @doc """
  Invites a user (by email) into the account with the given role.

  If no user with that email exists, a placeholder user is created
  (unconfirmed, no password) so we have something to hang the
  membership and invitation token off of. Returns
  `{:ok, %{membership: m, user: u, invitation_token: token}}` on success,
  or `{:error, :already_member}` if the user already belongs to the account.

  The caller is responsible for sending the invitation email; this
  context only persists the records and mints the token.
  """
  def invite_user_to_account(email, role, %Subject{account: %Account{id: account_id}} = subject)
      when is_binary(email) and is_binary(role) do
    with :ok <- ensure_invite_permitted(role, subject) do
      email = String.downcase(String.trim(email))
      token = Crypto.user_invite_token()

      Multi.new()
      |> Multi.run(:user, fn _repo, _changes -> Users.fetch_or_create_user_by_email(email) end)
      |> Multi.insert(:membership, fn %{user: user} ->
        Membership.Changeset.create(%{
          account_id: account_id,
          user_id: user.id,
          role: role,
          invited_by_id: subject.actor.id,
          invitation_token: token
        })
      end)
      |> Multi.insert(:audit, fn %{user: user} ->
        Audit.Events.user_invited(subject, user, role)
      end)
      |> Repo.commit_multi()
      |> case do
        {:ok, %{user: user, membership: membership}} ->
          {:ok, %{membership: membership, user: user, invitation_token: token}}

        # The partial unique index on (account_id, user_id) is the source of
        # truth for "already a member" — let the insert hit it instead of a
        # read-before-write check that races under concurrent invites.
        {:error, %Ecto.Changeset{data: %Membership{}} = changeset} ->
          if Repo.Changeset.unique_constraint_error?(changeset),
            do: {:error, :already_member},
            else: {:error, changeset}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Inviting needs the base invite_member permission, and you can't invite
  # someone at a role whose permissions you don't already hold — the same
  # no-escalation rule as role changes (Authorizer.covers_role?/2).
  defp ensure_invite_permitted(role, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.invite_member_permission()
           ) do
      case Role.cast(role) do
        {:ok, role} ->
          if Auth.Authorizer.covers_role?(subject, role),
            do: :ok,
            else: {:error, :insufficient_privileges}

        # Unknown role names fall through to the membership changeset,
        # where Ecto.Enum rejects them with a field error.
        :error ->
          :ok
      end
    end
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
    |> Membership.Query.with_preloaded_account()
    |> Membership.Query.with_preloaded_user()
    |> Repo.fetch(Membership.Query)
  end

  def fetch_invitation_by_token(_), do: {:error, :not_found}

  @doc """
  Marks an invitation accepted without touching the user record. Used when
  an already-signed-in user clicks an invite link for one of their own
  accounts — the user already has a password + confirmed_at, so we just clear
  the token + stamp `invitation_accepted_at`.

  The accepting user must BE the invited user (the membership's `user_id`):
  a signed-in *different* user holding the token (e.g. a forwarded link) must
  not be able to burn the invitation. Returns `{:error, :unauthorized}`
  otherwise. Takes the `%User{}` (not a `%Subject{}`) — the accept-invite page
  is a public route with only `current_user` assigned, no subject.
  """
  def mark_invitation_accepted(%Membership{user_id: user_id} = membership, %User{id: user_id}) do
    now = DateTime.utc_now()

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

  def mark_invitation_accepted(%Membership{}, %User{}), do: {:error, :unauthorized}

  @doc """
  Accepts a membership invitation: sets the user's full_name + password,
  clears the invitation token, marks invitation_accepted_at. Confirms
  the user since the invitation acceptance proves they own the email.

  Wrapped in a transaction so a half-accepted state is impossible.
  """
  def accept_invitation(%Membership{} = membership, %{} = user_attrs) do
    now = DateTime.utc_now()

    Multi.new()
    |> Multi.run(:existing_user, fn _repo, _changes ->
      Users.fetch_user_by_id(membership.user_id)
    end)
    |> Multi.run(:user, fn _repo, %{existing_user: existing_user} ->
      Users.register_invited_user(existing_user, user_attrs)
    end)
    |> Multi.update(
      :membership,
      Ecto.Changeset.change(membership, invitation_token: nil, invitation_accepted_at: now)
    )
    |> Multi.insert(:audit, fn %{user: user, membership: updated} ->
      Audit.Events.user_invitation_accepted(user, updated)
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{user: user, membership: updated}} -> {:ok, %{user: user, membership: updated}}
      {:error, reason} -> {:error, reason}
    end
  end

  # -- Internal (Billing flows) -------------------------------------------
  # Account/membership reads + the one account write the Billing context
  # needs. Billing owns the plan/limit semantics; the row mechanics stay
  # here. Never exposed to LiveView/controllers/MCP.

  @doc """
  Internal — Billing seat counting: membership rows in the account.
  Counts suspended members too — suspension preserves the seat (role +
  history kept for reinstate), it doesn't free it.
  """
  def count_memberships(account_id) do
    Membership.Query.all()
    |> Membership.Query.by_account_id(account_id)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Internal — Billing webhook resolve: the account a Paddle customer id
  belongs to, nil-or-struct (`peek` — an unknown cid is a meaningful
  no-match the webhook handler no-ops on).
  """
  def peek_account_by_paddle_customer_id(cid) when is_binary(cid) do
    Account.Query.all()
    |> Account.Query.by_paddle_customer_id(cid)
    |> Repo.peek()
  end

  @doc "Internal — Billing: stamp the Paddle customer id after first checkout."
  def put_account_paddle_customer_id(%Account{} = account, cid) when is_binary(cid) do
    account |> Account.Changeset.link_paddle_customer(cid) |> Repo.update()
  end

  # -- Authorization ----------------------------------------------------

  @doc "Whether `subject` may manage team memberships (admin+)."
  def subject_can_manage_team?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.manage_team_permission())

  @doc """
  Whether `subject` may change account security settings such as MFA
  enforcement — owner-only.
  """
  def subject_can_manage_account_security?(%Subject{} = subject) do
    Auth.Authorizer.has_permission?(subject, Authorizer.manage_security_settings_permission())
  end
end
