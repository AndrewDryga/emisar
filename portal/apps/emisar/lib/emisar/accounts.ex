defmodule Emisar.Accounts do
  @moduledoc """
  The multi-tenant boundary. Manages accounts (orgs), users, and the
  memberships that join them with a role.

  Every read API in the rest of the system is expected to scope by
  account; this context owns the slug-based lookups and signup flow.
  """
  alias Ecto.Multi
  alias Emisar.Accounts.{Account, Authorizer, Membership}
  alias Emisar.{ApiKeys, Audit, Auth, Crypto, Mail, Repo, Slug, SSO, Users}
  alias Emisar.Auth.Subject
  require Logger

  # -- Accounts ---------------------------------------------------------

  # Account lookups by id / slug are pre-authentication — they're how
  # `UserAuth.assign_current_account` and the public `/onboarding` path
  # resolve an account before there's a Subject to authorize with.
  # They intentionally don't take a Subject; callers operating in an
  # authenticated context should prefer `socket.assigns.current_account`
  # over re-fetching.

  @doc "Internal — pre-auth account lookup for `UserAuth.assign_current_account`; no subject exists yet."
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
  Internal — pre-auth: the web session boundary (`UserAuth`) resolves an
  `/app/:account_id_or_slug` segment before anyone is authenticated, so no
  subject exists yet. The segment is a UUID (API / SSO / redirects) or the slug
  (the canonical UI form). Scopes nothing — knowing a slug grants no access (the
  slug gate on the authenticated routes is the authz boundary).
  """
  def fetch_account_by_id_or_slug(id_or_slug) when is_binary(id_or_slug) do
    queryable = Account.Query.not_deleted()

    queryable =
      if Repo.valid_uuid?(id_or_slug),
        do: Account.Query.by_id(queryable, id_or_slug),
        else: Account.Query.by_slug(queryable, id_or_slug)

    Repo.fetch(queryable, Account.Query)
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
  def list_accounts_for_user(%Subject{actor: %Users.User{id: user_id}}, opts \\ []) do
    Account.Query.not_deleted()
    |> Account.Query.by_membership_user_id(user_id)
    |> Account.Query.ordered_by_name()
    |> Repo.list(Account.Query, opts)
  end

  @doc """
  Internal — onboarding/registration: called from signup where the user has no
  membership yet, so no `%Subject{}` can exist — owning the brand-new account is
  what creates one. Creates an account with the given user as `:owner`, wrapped
  in a transaction so a half-created account is impossible. Audit-logs both
  `user.signed_up` (the new user) and `account.created` (the new tenant) —
  together they form the "this person stood up a new team" trace operators need
  for billing/abuse review.
  """
  def create_account_with_owner(account_attrs, %Users.User{} = user) do
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
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_own_account_permission()
           ),
         :ok <- ensure_subject_owns_account(subject, account) do
      Account.Query.not_deleted()
      |> Account.Query.by_id(account.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Account.Query,
        with: fn loaded_account ->
          # The owner-only escalation is judged on the FRESH diff under
          # the row lock, so the gate covers exactly what gets written —
          # a stale-struct diff could smuggle a `require_mfa` flip past
          # it when the caller's copy and the row disagree.
          changeset = Account.Changeset.update(loaded_account, attrs)

          case ensure_security_change_permitted(changeset, subject) do
            :ok -> changeset
            {:error, reason} -> reason
          end
        end,
        audit: &account_update_audit(&1, &2, subject)
      )
    end
  end

  def change_account(%Account{} = account, attrs \\ %{}) do
    Account.Changeset.update(account, attrs)
  end

  # Field-aware authorization: a security-setting change requires the
  # owner-only permission on top of the manage_own_account gate already
  # checked at the entry; a plain rename/rebrand needs nothing more.
  defp ensure_security_change_permitted(%Ecto.Changeset{} = changeset, %Subject{} = subject) do
    if security_setting_changed?(changeset) do
      Auth.Authorizer.ensure_has_permissions(
        subject,
        Authorizer.manage_security_settings_permission()
      )
    else
      :ok
    end
  end

  # require_mfa and require_sso are the security settings.
  defp security_setting_changed?(%Ecto.Changeset{changes: changes}),
    do: Map.has_key?(changes, :require_mfa) or Map.has_key?(changes, :require_sso)

  # A require_mfa / require_sso change is a security event; everything else is a
  # plain account.updated. The UI never changes more than one in a request.
  defp account_update_audit(
         %Account{} = account,
         %Ecto.Changeset{} = changeset,
         %Subject{} = subject
       ) do
    cond do
      Map.has_key?(changeset.changes, :require_mfa) ->
        Audit.Events.account_require_mfa_set(subject, account)

      Map.has_key?(changeset.changes, :require_sso) ->
        Audit.Events.account_require_sso_set(subject, account)

      true ->
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

  defp do_suggest(base, attempt) do
    candidate = if attempt == 0, do: base, else: "#{base}-#{attempt}"

    taken? =
      Account.Query.not_deleted()
      |> Account.Query.by_slug(candidate)
      |> Repo.exists?()

    if taken?, do: do_suggest(base, attempt + 1), else: candidate
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
      {preloads, opts} = Keyword.pop(opts, :preload, [])

      Membership.Query.not_deleted()
      |> Membership.Query.by_account_id(account_id)
      |> apply_membership_preloads(preloads)
      |> Authorizer.for_subject(subject)
      |> Repo.list(Membership.Query, opts)
    end
  end

  # Rendering concerns are the caller's: pass `preload: [:user]` (and/or
  # `:account`) only when the page actually shows those fields — a
  # counting or existence caller pays for no joins. Unknown atoms raise.
  defp apply_membership_preloads(queryable, preloads) do
    Enum.reduce(preloads, queryable, fn
      :account, queryable -> Membership.Query.with_preloaded_account(queryable)
      :user, queryable -> Membership.Query.with_preloaded_user(queryable)
    end)
  end

  @doc """
  Account-wide 2FA enrollment for the team security stat: total members
  and how many have completed MFA — real counts, not a per-page tally that
  reads falsely reassuring on a multi-page team. Requires `view_own_account`
  and that `subject` is in the account. Returns
  `{:ok, %{total: non_neg_integer, enrolled: non_neg_integer}}`.
  """
  def team_mfa_stats(%Account{id: account_id}, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_own_account_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, account_id, :unauthorized) do
      base = Membership.Query.not_deleted() |> Membership.Query.by_account_id(account_id)

      total = base |> Authorizer.for_subject(subject) |> Repo.aggregate(:count)

      enrolled =
        base
        |> Membership.Query.with_mfa_enrolled()
        |> Authorizer.for_subject(subject)
        |> Repo.aggregate(:count)

      {:ok, %{total: total, enrolled: enrolled}}
    end
  end

  @doc """
  Of this account's members and pending invitations, the set of emails on the
  global deliverability suppression list — addresses that hard-bounced or filed
  a complaint, so an invite/notification to them was dropped. Surfaced on the
  Team page so an admin can see why a teammate never got their invite (and
  contact support to clear it). Derives the emails server-side and only ever
  checks this account's own addresses, so no caller can probe the global list.
  Requires `view_own_account` and that `subject` is in the account. Returns
  `{:ok, MapSet.t(String.t())}`.
  """
  def suppressed_member_emails(%Account{id: account_id}, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_own_account_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, account_id, :unauthorized) do
      emails =
        Membership.Query.not_deleted()
        |> Membership.Query.by_account_id(account_id)
        |> Membership.Query.select_user_emails()
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, Mail.suppressed_emails(emails)}
    end
  end

  @doc """
  Internal: account-scoped membership page for system fan-outs (the approval
  notifier, which emails every approver). No `%Subject{}` — the caller is a
  background job already scoped to this account; pages via `opts` like the
  public `list_memberships_for_account/3`.
  """
  def list_account_memberships(account_id, opts \\ []) do
    # `user` is this helper's contract — the notifier addresses the email
    # from it. (No account preload: nothing downstream reads it.)
    Membership.Query.not_deleted()
    |> Membership.Query.by_account_id(account_id)
    |> Membership.Query.with_preloaded_user()
    |> Repo.list(Membership.Query, opts)
  end

  @doc """
  Internal — SSO: create a membership for a JIT-provisioned user at the
  provider's `default_role`. No `%Subject{}` — the caller is the pre-auth SSO
  callback, scoped to the provider's account; composed into the SSO JIT
  `Multi` via `Multi.run`. The JIT user is always brand-new, so the
  `(account, user)` unique can't fire here.
  """
  # Defense in depth: `:owner` is never assignable via sync (the provider
  # changeset rejects it as a default_role too) — owner is a deliberate human
  # grant needing `manage_owners`.
  def provision_sso_membership(_account_id, _user_id, :owner), do: {:error, :owner_not_assignable}

  def provision_sso_membership(account_id, user_id, role) do
    %{account_id: account_id, user_id: user_id, role: role}
    |> Membership.Changeset.create()
    |> Repo.insert()
  end

  @doc """
  Internal — the runbook engine's per-wave authorization re-check: the
  membership `membership_id` in `account_id`, nil-or-struct, ONLY if it is still
  active (not deleted, not disabled). No `%Subject{}` — the caller is the
  user-less runbook continuation, which already authorized at first dispatch and
  re-validates the anchor here before each wave. A `nil` result means the
  initiating member was suspended/deleted mid-execution → the engine halts.
  """
  def peek_active_membership(account_id, membership_id)
      when is_binary(account_id) and is_binary(membership_id) do
    Membership.Query.not_deleted()
    |> Membership.Query.not_disabled()
    |> Membership.Query.by_account_id(account_id)
    |> Membership.Query.by_id(membership_id)
    |> Repo.peek()
  end

  def peek_active_membership(_account_id, _membership_id), do: nil

  @doc """
  Internal — directory sync: the membership joining `account_id` + `user_id`,
  nil-or-struct (a SCIM reconcile reads it back for the response resource).
  No `%Subject{}` — the caller is the provider-scoped SCIM path. Returns the
  row regardless of `disabled_at` (a deprovisioned member still has one).
  """
  def peek_sync_membership(account_id, user_id) do
    Membership.Query.not_deleted()
    |> Membership.Query.by_account_and_user(account_id, user_id)
    |> Repo.peek()
  end

  @doc """
  Internal — the sync memberships for a SET of users in an account, in one query
  (the SSO group reconcile's batched membership lookup; no `%Subject{}` — the
  caller is the provider-scoped SCIM path).
  """
  def list_sync_memberships(account_id, user_ids) do
    Membership.Query.not_deleted()
    |> Membership.Query.by_account_id(account_id)
    |> Membership.Query.by_user_ids(user_ids)
    |> Repo.all()
  end

  @doc """
  Internal — pre-auth: called by the web session boundary (`UserAuth`) to build
  `current_account`/`current_user` before there's a Subject to authorize with.
  Resolves the membership to mount as the user's active tenant for this request:
  if `account_id` is given and the user has a non-suspended membership on that
  (non-deleted) account, return it; otherwise fall back to the most
  recently-joined non-suspended membership — the default for first sign-in or
  after a stale session value is cleared. Returns
  `{:ok, membership} | {:error, :not_found}`.
  """
  def fetch_membership_for_session(%Users.User{id: user_id}, account_id) do
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
  Internal — pre-auth: called by the web session boundary
  (`UserAuth.on_mount(:ensure_account_slug)`) on every authenticated mount; the
  slug IS the cross-account authz input, re-resolved here (not trusted from the
  session), so no `%Subject{}` exists yet. Resolves the membership for an
  `/app/:account_id_or_slug` segment, scoped to the user's OWN memberships. The
  segment is a UUID (API / SSO / temporary redirects) or the slug (the canonical
  UI form). A non-member or unknown ref both return `{:error, :not_found}` —
  indistinguishable, so a slugged URL never confirms a tenant exists (404, never
  403). Suspended (`disabled_at`) members and soft-deleted accounts/users are
  excluded.
  """
  def fetch_membership_by_account_id_or_slug(%Users.User{id: user_id}, account_id_or_slug) do
    Membership.Query.not_deleted()
    |> Membership.Query.by_user_id(user_id)
    |> Membership.Query.not_disabled()
    |> scope_to_account_ref(account_id_or_slug)
    |> Membership.Query.with_preloaded_account()
    |> Membership.Query.with_preloaded_user()
    |> Repo.fetch(Membership.Query)
  end

  defp scope_to_account_ref(queryable, account_id_or_slug) do
    if Repo.valid_uuid?(account_id_or_slug) do
      Membership.Query.by_account_id(queryable, account_id_or_slug)
    else
      Membership.Query.by_account_slug(queryable, account_id_or_slug)
    end
  end

  @doc """
  Internal — called by the web session boundary (`UserAuth`) when an operator
  switches active tenant; the switch is web session state (no rows change), so
  no `%Subject{}` is threaded, but the audit trail of it is the domain's record —
  controllers never write audit rows. Takes the membership resolved by
  `fetch_membership_for_session/2` (`:user` preloaded).
  """
  def record_account_switched(%Membership{} = membership) do
    membership |> Audit.Events.session_account_switched() |> Repo.insert()
  end

  @doc """
  Internal — predicate composed by the web session checks (`UserAuth`) /
  sibling contexts, off a `%Users.User{}` with no subject yet. True if every
  membership the user holds is suspended (and they have at least one). Distinct
  from "user has no memberships" — the UI needs to show "your access was
  suspended" rather than send them to onboarding.
  """
  def all_memberships_suspended?(%Users.User{id: user_id}) do
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
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_team_permission()),
         :ok <- ensure_subject_in_account(subject, membership.account_id),
         {:ok, new_role} <- cast_new_role(membership, new_role) do
      Membership.Query.not_deleted()
      |> Membership.Query.by_id(membership.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Membership.Query,
        with: fn loaded_membership ->
          # The hierarchy guards judge the row's CURRENT role under the
          # lock — the caller's struct is a stale socket snapshot, and a
          # concurrent promotion must not let a stale-admin demote a
          # freshly-promoted owner.
          with :ok <- ensure_role_change_allowed(loaded_membership, new_role, subject),
               :ok <- ensure_demotion_keeps_an_owner(loaded_membership, new_role) do
            Membership.Changeset.update(loaded_membership, %{role: new_role})
          else
            {:error, reason} -> reason
          end
        end,
        # `changeset.data` is the locked pre-update row — the audit
        # payload records the role that was actually replaced. (A capture
        # can't skip &1, so this stays a fn.)
        audit: fn _updated, changeset ->
          Audit.Events.membership_role_changed(subject, changeset.data, new_role)
        end,
        after_commit: &on_membership_role_changed/2
      )
    end
  end

  # -- PubSub ----------------------------------------------------------

  @doc "Subscribe the caller to the account's team list changes (`{:list_changed, :team, …}`)."
  def subscribe_account_team(account_id),
    do: Emisar.PubSub.subscribe(account_team_topic(account_id))

  defp account_team_topic(account_id), do: "account:#{account_id}:team"

  defp broadcast_membership_role_changed(%Membership{} = membership) do
    Emisar.PubSub.broadcast(
      account_team_topic(membership.account_id),
      {:list_changed, :team, "membership.role_changed", membership.user_id}
    )
  end

  # after_commit for both role-change paths (operator UI + SCIM sync): refresh
  # the team list AND, on a privilege REDUCTION, force the member's open sockets
  # to remount with the new permissions. `changeset.data.role` is the locked
  # pre-update role.
  defp on_membership_role_changed(%Membership{} = membership, %Ecto.Changeset{} = changeset) do
    broadcast_membership_role_changed(membership)
    maybe_refresh_reduced_member_sessions(changeset.data.role, membership)
  end

  # A role change rewrites the user's permission set, but a mounted LiveView
  # snapshotted the OLD %Subject{} at mount — so a demoted operator/admin keeps
  # stale powers on every open socket until they happen to navigate. On a
  # REDUCTION, disconnect the member's live sockets (sockets only — they stay
  # signed in) so each remounts and rebuilds its subject from the new role.
  #
  # Authz here is permission-based, not rank-based (`Auth.Role` deliberately has
  # no rank), so "reduction" is a permission-subset test — the new role losing a
  # permission the old one held. An elevation or a no-op (a SCIM reconcile
  # re-applying the same role) keeps the sockets, avoiding needless reconnects.
  defp maybe_refresh_reduced_member_sessions(old_role, %Membership{role: new_role} = membership) do
    if reduced_permissions?(old_role, new_role) do
      refresh_member_sessions(membership)
    else
      :ok
    end
  end

  defp reduced_permissions?(old_role, new_role),
    do:
      not MapSet.subset?(Auth.Permissions.for_role(old_role), Auth.Permissions.for_role(new_role))

  defp refresh_member_sessions(%Membership{} = membership) do
    case Users.fetch_user_by_id(membership.user_id) do
      {:ok, user} -> Auth.broadcast_disconnect_for_user(user)
      {:error, _reason} -> :ok
    end
  end

  defp broadcast_membership_suspended(%Membership{} = membership) do
    Emisar.PubSub.broadcast(
      account_team_topic(membership.account_id),
      {:list_changed, :team, "membership.suspended", membership.user_id}
    )
  end

  defp broadcast_membership_reinstated(%Membership{} = membership) do
    Emisar.PubSub.broadcast(
      account_team_topic(membership.account_id),
      {:list_changed, :team, "membership.reinstated", membership.user_id}
    )
  end

  defp broadcast_membership_removed(%Membership{} = membership) do
    Emisar.PubSub.broadcast(
      account_team_topic(membership.account_id),
      {:list_changed, :team, "membership.removed", membership.user_id}
    )
  end

  # The last-owner invariant is NOT checked here — a pre-transaction
  # count races a concurrent demotion (two operators demoting the two
  # last owners both pass `count > 1`); `ensure_not_last_active_owner/1`
  # re-checks under the row lock inside each mutation's transaction.
  defp ensure_role_change_allowed(%Membership{} = membership, new_role, %Subject{} = subject) do
    cond do
      # Can't grant a role whose permissions you don't already hold (no
      # escalation by proxy). On your own membership that's self-promotion.
      not Auth.Permissions.covers_role?(subject, new_role) ->
        if membership.user_id == subject.actor.id,
          do: {:error, :cannot_self_promote},
          else: {:error, :insufficient_privileges}

      # Can't change the role of someone whose permissions outrank yours.
      not Auth.Permissions.covers_role?(subject, membership.role) ->
        {:error, :insufficient_privileges}

      true ->
        :ok
    end
  end

  # The changeset's Ecto.Enum cast turns the submitted role name into its
  # atom, or rejects an unknown one — no hand-rolled role coercion. The
  # write itself rebuilds the changeset on the locked row inside
  # `fetch_and_update`'s `:with`.
  defp cast_new_role(%Membership{} = membership, new_role) do
    changeset = Membership.Changeset.update(membership, %{role: new_role})

    if changeset.valid? do
      {:ok, Ecto.Changeset.get_field(changeset, :role)}
    else
      {:error, changeset}
    end
  end

  # Locked-target prefix for the membership mutations that go on to
  # write OTHER rows (the member's user record, their session tokens):
  # one `:target` step that re-reads the membership under the row lock
  # and runs the hierarchy guard against the fresh copy — the caller's
  # struct is a stale socket snapshot. Mutations that write the
  # membership row itself use `Repo.fetch_and_update/3` instead.
  defp lock_target_membership(multi, %Membership{} = membership, guard) do
    Multi.run(multi, :target, fn repo, _changes ->
      with {:ok, loaded_membership} <- lock_membership(repo, membership),
           :ok <- guard.(loaded_membership) do
        {:ok, loaded_membership}
      end
    end)
  end

  # `nil` means the member vanished mid-flight.
  defp lock_membership(repo, %Membership{} = membership) do
    loaded_membership =
      Membership.Query.not_deleted()
      |> Membership.Query.by_id(membership.id)
      |> Membership.Query.lock_for_update()
      |> repo.one()

    if loaded_membership,
      do: {:ok, loaded_membership},
      else: {:error, :not_found}
  end

  # Refuses to take the account's last ACTIVE owner out of play. Runs
  # inside the caller's transaction (a plain `Repo` call joins it): it
  # locks the account's active owner rows (`FOR NO KEY UPDATE`), so two
  # concurrent demote/suspend/remove calls serialize and the loser
  # re-counts the winner's committed state — a pre-transaction count is
  # a TOCTOU that could leave the account ownerless.
  defp ensure_not_last_active_owner(%Membership{role: :owner} = membership) do
    owners =
      Membership.Query.not_deleted()
      |> Membership.Query.by_account_id(membership.account_id)
      |> Membership.Query.by_role(:owner)
      |> Membership.Query.not_disabled()
      |> Membership.Query.lock_for_update()
      |> Repo.all()

    if length(owners) > 1, do: :ok, else: {:error, :last_owner}
  end

  # A non-owner leaving play never threatens owner coverage.
  defp ensure_not_last_active_owner(%Membership{}), do: :ok

  # A role change only threatens owner coverage when it demotes an owner.
  defp ensure_demotion_keeps_an_owner(%Membership{role: :owner} = membership, new_role)
       when new_role != :owner,
       do: ensure_not_last_active_owner(membership)

  defp ensure_demotion_keeps_an_owner(%Membership{}, _new_role), do: :ok

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
         :ok <- ensure_subject_in_account(subject, membership.account_id) do
      Membership.Query.not_deleted()
      |> Membership.Query.by_id(membership.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Membership.Query,
        with: fn loaded_membership ->
          # The guards judge the row's CURRENT role under the lock — the
          # caller's struct is a stale socket snapshot.
          with :ok <- ensure_can_modify_membership(loaded_membership, subject),
               :ok <- ensure_not_last_active_owner(loaded_membership) do
            Membership.Changeset.suspend(loaded_membership)
          else
            {:error, reason} -> reason
          end
        end,
        audit: &Audit.Events.membership_suspended(subject, &1),
        after_commit: [
          # Broadcast first so the team-page LV refreshes the row before
          # we kill the user's sessions — keeps the visual ordering sane.
          &broadcast_membership_suspended/1,
          # Session + key kill are side effects — only fire after the
          # suspension actually commits. Otherwise a rolled-back update
          # would still kick the user out of every tab / kill their keys.
          &disconnect_user_sessions/1,
          &revoke_membership_api_keys/1
        ]
      )
    end
  end

  # Revoke the API keys this membership minted — a removed or suspended
  # user must lose their delegated execute access. Keys are account-scoped,
  # so unlike sessions (which self-heal at membership resolution) they keep
  # working until revoked; this kills MCP `emk-` dispatch and the OAuth
  # backing keys behind `emo-` tokens together.
  defp revoke_membership_api_keys(%Membership{} = membership) do
    {:ok, _count} = ApiKeys.revoke_keys_for_membership(membership.id)
    :ok
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
         :ok <- ensure_subject_in_account(subject, membership.account_id) do
      Membership.Query.not_deleted()
      |> Membership.Query.by_id(membership.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Membership.Query,
        with: fn loaded_membership ->
          # The guard judges the row's CURRENT role under the lock — the
          # caller's struct is a stale socket snapshot.
          case ensure_can_modify_membership(loaded_membership, subject) do
            :ok -> Membership.Changeset.reinstate(loaded_membership)
            {:error, reason} -> reason
          end
        end,
        audit: &Audit.Events.membership_reinstated(subject, &1),
        after_commit: &broadcast_membership_reinstated/1
      )
    end
  end

  @doc """
  Internal — directory sync: suspend a member because the IdP deprovisioned
  them (SCIM `active:false` / DELETE). No `%Subject{}` — the SCIM bearer's
  provider-scope is the authorization, validated at the web boundary; the
  `provider` is threaded only to attribute the audit to the directory.

  Mirrors `suspend_membership/2`'s mechanics exactly — `disabled_at` under
  the row lock, then kill sessions + revoke API keys + broadcast — and the
  **last-active-owner guard still fires**: a directory deprovision can never
  lock out the account's last owner (§9 N5). Returns
  `{:ok, membership} | {:error, :last_owner | :not_found}`.
  """
  def sync_suspend_membership(%Membership{} = membership, %SSO.IdentityProvider{} = provider) do
    Membership.Query.not_deleted()
    |> Membership.Query.by_id(membership.id)
    |> Repo.fetch_and_update(Membership.Query,
      with: fn loaded_membership ->
        # Guards judge the locked row: it must live in the provider's account
        # (the directory-sync authz boundary), and a deprovision can never lock
        # out the account's last owner.
        with :ok <- ensure_membership_in_provider_account(loaded_membership, provider),
             :ok <- ensure_not_last_active_owner(loaded_membership) do
          Membership.Changeset.suspend(loaded_membership)
        else
          {:error, reason} -> reason
        end
      end,
      audit: &Audit.Events.membership_deprovisioned_via_scim(&1, provider),
      after_commit: [
        &broadcast_membership_suspended/1,
        &disconnect_user_sessions/1,
        &revoke_membership_api_keys/1
      ]
    )
  end

  @doc """
  Internal — directory sync: reinstate a member the IdP re-provisioned
  (SCIM `active:true`). No `%Subject{}` — see `sync_suspend_membership/2`.
  Clears `disabled_at` under the row lock + broadcasts. Returns
  `{:ok, membership} | {:error, :not_found}`.
  """
  def sync_reinstate_membership(%Membership{} = membership, %SSO.IdentityProvider{} = provider) do
    Membership.Query.not_deleted()
    |> Membership.Query.by_id(membership.id)
    |> Repo.fetch_and_update(Membership.Query,
      with: fn loaded_membership ->
        # The locked row must live in the provider's account before we write.
        case ensure_membership_in_provider_account(loaded_membership, provider) do
          :ok -> Membership.Changeset.reinstate(loaded_membership)
          {:error, reason} -> reason
        end
      end,
      audit: &Audit.Events.membership_reprovisioned_via_scim(&1, provider),
      after_commit: &broadcast_membership_reinstated/1
    )
  end

  @doc """
  Internal — directory sync: set a member's role from their mapped IdP groups
  (Slice 2b). No `%Subject{}` — the SCIM bearer's provider-scope is the
  authorization, validated at the web boundary; the `provider` is threaded
  only to attribute the audit to the directory.

  Defense in depth even though group→role mappings already exclude `:owner`
  (decision 7): the `:with` **refuses `:owner`** under the lock, and it **never
  demotes the account's last active owner** (`ensure_not_last_active_owner` when
  the CURRENT role is `:owner` and the new role isn't — §9 N5). Idempotent: if
  the role already matches, returns `{:ok, membership}` with no write or audit.
  Returns `{:ok, membership} | {:error, :owner_not_assignable | :last_owner |
  :not_found | %Ecto.Changeset{}}`.
  """
  def sync_set_membership_role(
        %Membership{role: role} = membership,
        role,
        %SSO.IdentityProvider{}
      ),
      do: {:ok, membership}

  def sync_set_membership_role(
        %Membership{} = membership,
        role,
        %SSO.IdentityProvider{} = provider
      ) do
    Membership.Query.not_deleted()
    |> Membership.Query.by_id(membership.id)
    |> Repo.fetch_and_update(Membership.Query,
      with: fn loaded_membership ->
        # The guards judge the locked row — the caller's struct is a stale socket
        # snapshot. It must live in the provider's account, owner stays a human
        # assignment, and we never demote the account's last owner.
        with :ok <- ensure_membership_in_provider_account(loaded_membership, provider),
             :ok <- ensure_sync_role_assignable(role),
             :ok <- ensure_demotion_keeps_an_owner(loaded_membership, role) do
          Membership.Changeset.update(loaded_membership, %{role: role})
        else
          {:error, reason} -> reason
        end
      end,
      # `changeset.data` is the locked pre-update row — record the role that
      # was actually replaced. Skip the audit when the locked row already
      # carried this role (a concurrent reconcile beat us to it — no change).
      audit: fn _updated, changeset ->
        if changeset.data.role == role,
          do: nil,
          else: Audit.Events.membership_role_synced_via_scim(changeset.data, provider, role)
      end,
      after_commit: &on_membership_role_changed/2
    )
  end

  # Directory sync can never grant owner — owner stays a deliberate human
  # assignment (decision 7). The group→role mapping changeset already excludes
  # it; this is the write-path backstop.
  defp ensure_sync_role_assignable(:owner), do: {:error, :owner_not_assignable}
  defp ensure_sync_role_assignable(_role), do: :ok

  # The provider's account IS the authorization on the directory-sync path (no
  # %Subject{}), so the locked membership must live in it before we write — the
  # account scoping the Subject-gated siblings get from `ensure_subject_in_account`
  # + `for_subject`. Equal `account_id` bindings unify; a membership from any other
  # account can't have come from this provider.
  defp ensure_membership_in_provider_account(
         %Membership{account_id: account_id},
         %SSO.IdentityProvider{account_id: account_id}
       ),
       do: :ok

  defp ensure_membership_in_provider_account(_membership, _provider), do: {:error, :not_found}

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
         :ok <- ensure_subject_in_account(subject, membership.account_id) do
      # Users nulls the hash + inserts our audit atomically under the row
      # lock; the old credential stops working the moment this commits.
      # The membership guard runs on a locked re-read in the same
      # transaction so the hierarchy is judged on the CURRENT role.
      #
      # Sending the reset email + broadcasting disconnects are side
      # effects that must NOT happen if the password-null update rolled
      # back. We pass `audit: false` to the token mint so it doesn't
      # ALSO emit a `user.password_reset_requested` row — that row would
      # attribute the action to the TARGET user as actor, not the admin
      # who triggered it. The `user.password_reset_forced` event below is
      # the canonical record with the correct actor → subject pair.
      Multi.new()
      |> lock_target_membership(membership, &ensure_can_modify_membership(&1, subject))
      |> Multi.run(:user, fn _repo, %{target: loaded_membership} ->
        Users.clear_user_password(loaded_membership.user_id,
          audit: &Audit.Events.user_password_reset_forced(subject, loaded_membership, &1)
        )
      end)
      |> Repo.commit_multi(
        # On the OUTER commit, not the nested update's — a nested
        # after_commit fires while this transaction is still open, so a
        # commit-time failure would kick the user + email a reset for a
        # rollback. fetch_and_update raises on that misuse now.
        after_commit: fn %{user: user} ->
          :ok = Emisar.Auth.disconnect_and_revoke_all_sessions(user)
          token = Emisar.Auth.issue_password_reset_token!(user, audit: false)
          _ = Emisar.Mailers.UserNotifier.deliver_password_reset(user, token)
          :ok
        end
      )
      |> case do
        {:ok, _changes} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Admin-triggered MFA reset: clears a member's enrolled second factor
  (TOTP secret + recovery codes) so a member locked out of BOTH their
  authenticator and their recovery codes can re-enroll on next sign-in —
  the only path out of a full lockout short of support. Same
  authorization shape as the rest of `ensure_can_modify_membership`: the
  admin must be in the target's account and outrank them (an admin can't
  reset an owner's MFA), and can't reset their own (self-service
  `Auth.disable_mfa/1` is that path). Audit-logged as
  `user.mfa_reset_by_admin`.

  This is an MFA-bypass surface — clearing a factor lets that member
  enroll a NEW one — so it is gated, hierarchy-checked, and audited
  exactly like `force_password_reset/2`, never self-matched.
  """
  def reset_member_mfa(%Membership{} = membership, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_team_permission()),
         :ok <- ensure_subject_in_account(subject, membership.account_id) do
      # Users clears the MFA fields + inserts our audit atomically under
      # the row lock; the member's old factor stops working the moment
      # this commits. The membership guard runs on a locked re-read in the
      # same transaction so the hierarchy is judged on the CURRENT role.
      Multi.new()
      |> lock_target_membership(membership, &ensure_can_modify_membership(&1, subject))
      |> Multi.run(:user, fn _repo, %{target: loaded_membership} ->
        Users.reset_user_mfa(loaded_membership.user_id,
          audit: &Audit.Events.user_mfa_reset_by_admin(subject, loaded_membership, &1)
        )
      end)
      |> Repo.commit_multi()
      |> case do
        {:ok, %{user: user}} -> {:ok, user}
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
         :ok <- ensure_subject_in_account(subject, membership.account_id) do
      # Users whitelists the editable fields (full_name only — email and
      # password are deliberately not admin-editable, see moduledoc) and
      # holds the user-row lock while it writes + inserts our audit; the
      # membership guard re-reads under its own lock in the same
      # transaction so the hierarchy is judged on the CURRENT role.
      Multi.new()
      |> lock_target_membership(membership, &ensure_can_modify_membership(&1, subject))
      |> Multi.run(:user, fn _repo, %{target: loaded_membership} ->
        Users.update_user_profile_as_admin(loaded_membership.user_id, attrs,
          audit: &Audit.Events.user_updated_by_admin(subject, loaded_membership, &1)
        )
      end)
      |> Repo.commit_multi()
      |> case do
        {:ok, %{user: user}} -> {:ok, user}
        {:error, reason} -> {:error, reason}
      end
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
         :ok <- ensure_subject_in_account(subject, membership.account_id) do
      # The DB-side delete of session tokens is the source of truth — bundle
      # it with the audit row so we never end up with "tokens deleted but no
      # audit" or vice versa. The user read lives INSIDE the transaction so
      # it shares the snapshot with the delete (which Auth owns — token
      # internals stay private to it). The PubSub disconnect broadcast is a
      # side effect that fires only after the rows commit.
      Multi.new()
      |> lock_target_membership(membership, &ensure_can_modify_membership(&1, subject))
      |> Multi.run(:user, fn _repo, %{target: loaded_membership} ->
        Users.fetch_user_by_id(loaded_membership.user_id)
      end)
      |> Multi.run(:tokens, fn _repo, %{user: user} ->
        Emisar.Auth.delete_all_session_tokens(user)
      end)
      |> Multi.insert(:audit, fn %{target: loaded_membership, user: user} ->
        Audit.Events.user_sessions_revoked(subject, loaded_membership, user)
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

      not Auth.Permissions.covers_role?(subject, membership.role) ->
        {:error, :insufficient_privileges}

      true ->
        :ok
    end
  end

  @doc """
  Remove a membership, enforcing the same invariants as role updates:

    * You can only remove a member whose permissions you already hold, so a
      non-owner can't remove an owner.
    * The last active owner can't be removed (even by themselves).

  Removal is a soft delete — the tombstoned row keeps the role/invite
  history for review while every `not_deleted()` read (and the partial
  unique index on `(account_id, user_id)`) treats the member as gone, so
  the same user can be re-invited cleanly.
  """
  def delete_membership(%Membership{} = membership, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_team_permission()),
         :ok <- ensure_subject_in_account(subject, membership.account_id) do
      Membership.Query.not_deleted()
      |> Membership.Query.by_id(membership.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Membership.Query,
        with: fn loaded_membership ->
          # The guards judge the row's CURRENT role under the lock — the
          # caller's struct is a stale socket snapshot.
          with :ok <- ensure_delete_membership_allowed(loaded_membership, subject),
               :ok <- ensure_not_last_active_owner(loaded_membership) do
            Membership.Changeset.delete(loaded_membership)
          else
            {:error, reason} -> reason
          end
        end,
        audit: &Audit.Events.membership_removed(subject, &1),
        after_commit: [
          &broadcast_membership_removed/1,
          # A removed user's sessions self-heal at membership resolution,
          # but their minted API keys don't — revoke them so they can't
          # keep dispatching via MCP / OAuth after losing the account.
          &revoke_membership_api_keys/1
        ]
      )
    end
  end

  # The last-owner invariant lives in `ensure_not_last_active_owner/2`,
  # inside the Multi (see `ensure_role_change_allowed/3`'s note).
  defp ensure_delete_membership_allowed(%Membership{} = membership, %Subject{} = subject) do
    if Auth.Permissions.covers_role?(subject, membership.role) do
      :ok
    else
      {:error, :insufficient_privileges}
    end
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
    # Team seats are intentionally NOT capped (no Billing.check_limit(:members)
    # here, unlike the runner cap): giving away collaboration is a deliberate
    # growth lever — Free's members_limit + the Team meter are aspirational, not
    # gates. Revisit only if seat-based pricing lands. (PENDING_DECISIONS, 2026-06-14.)
    with :ok <- ensure_invite_permitted(role, subject) do
      # Trim only: `users.email` is citext, so lookup + uniqueness are
      # case-insensitive without app-side normalization (and registration
      # stores the typed casing — invites shouldn't differ).
      email = String.trim(email)
      {token, token_digest} = Crypto.user_invite_token()

      Multi.new()
      |> Multi.run(:user, fn _repo, _changes -> Users.fetch_or_create_user_by_email(email) end)
      |> Multi.insert(:membership, fn %{user: user} ->
        Membership.Changeset.create(%{
          account_id: account_id,
          user_id: user.id,
          role: role,
          invited_by_id: subject.actor.id,
          invitation_token_digest: token_digest
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
      case Auth.Role.cast(role) do
        {:ok, role} ->
          if Auth.Permissions.covers_role?(subject, role),
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
  Internal — invitation-accept flow: the opaque invite token IS the
  capability/authz, so there's no subject; used by the invitation-accept LV
  before the user has signed in. Looks up a pending membership by invitation
  token — the presented raw token is re-hashed for the lookup (only its digest
  is at rest) and invitations lapse after
  `Membership.Query.invitation_not_expired/1`'s window. Returns the membership
  with the requested preloads, or `{:error, :not_found}`.

  Options: `preload:` — associations the caller renders (`:account`,
  `:user`); omit when only the row itself is needed.
  """
  def fetch_invitation_by_token(token, opts \\ [])

  def fetch_invitation_by_token(token, opts) when is_binary(token) and byte_size(token) > 0 do
    {preloads, _opts} = Keyword.pop(opts, :preload, [])

    Membership.Query.not_deleted()
    |> Membership.Query.by_invitation_token_digest(Crypto.user_invite_token_digest(token))
    |> Membership.Query.pending_invitation()
    |> Membership.Query.invitation_not_expired()
    |> apply_membership_preloads(preloads)
    |> Repo.fetch(Membership.Query)
  end

  def fetch_invitation_by_token(_, _opts), do: {:error, :not_found}

  @doc """
  Internal — invitation-accept flow: takes the `%Users.User{}` (not a
  `%Subject{}`) because the accept-invite page is a public route with only
  `current_user` assigned. Marks an invitation accepted without touching the
  user record — used when an already-signed-in user clicks an invite link for
  one of their own accounts (they already have a password + confirmed_at, so we
  just clear the token + stamp `invitation_accepted_at`). The accepting user
  must BE the invited user (the membership's `user_id`): a signed-in *different*
  user holding the token (e.g. a forwarded link) must not be able to burn the
  invitation. Returns `{:error, :unauthorized}` otherwise.
  """
  def mark_invitation_accepted(%Membership{user_id: user_id} = membership, %Users.User{
        id: user_id
      }) do
    # Locked re-read judged on the FRESH row: a concurrently-accepted,
    # expired, or revoked invitation is :not_found — first accept wins,
    # never a blind re-stamp of the caller's stale snapshot.
    Membership.Query.not_deleted()
    |> Membership.Query.by_id(membership.id)
    |> Membership.Query.pending_invitation()
    |> Membership.Query.invitation_not_expired()
    |> Repo.fetch_and_update(Membership.Query,
      with: &Membership.Changeset.accept_invitation/1,
      audit: &Audit.Events.membership_invitation_accepted/1
    )
  end

  def mark_invitation_accepted(%Membership{}, %Users.User{}), do: {:error, :unauthorized}

  @doc """
  Internal — invitation-accept flow: the accept-invite page is a public route
  and the invitee has no session yet, so no `%Subject{}` exists; possession of
  the invitation token (resolved by `fetch_invitation_by_token/1`) is the
  authorization. Accepts a membership invitation: sets the user's full_name +
  password, clears the invitation token, marks invitation_accepted_at, and
  confirms the user since acceptance proves they own the email. Wrapped in a
  transaction so a half-accepted state is impossible.
  """
  def accept_invitation(%Membership{} = membership, %{} = user_attrs) do
    Multi.new()
    # Lock + re-judge the invitation FIRST: a token burnt between the
    # page mount and this submit (a second link holder racing the first
    # acceptor) must fail :not_found here — before register_invited_user
    # could overwrite the winner's freshly-set password.
    |> Multi.run(:membership, fn repo, _changes ->
      with {:ok, loaded_membership} <- lock_pending_invitation(repo, membership) do
        repo.update(Membership.Changeset.accept_invitation(loaded_membership))
      end
    end)
    |> Multi.run(:existing_user, fn _repo, _changes ->
      Users.fetch_user_by_id(membership.user_id)
    end)
    |> Multi.run(:user, fn _repo, %{existing_user: existing_user} ->
      Users.register_invited_user(existing_user, user_attrs)
    end)
    |> Multi.insert(:audit, fn %{user: user, membership: updated} ->
      Audit.Events.user_invitation_accepted(user, updated)
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{user: user, membership: updated}} -> {:ok, %{user: user, membership: updated}}
      {:error, reason} -> {:error, reason}
    end
  end

  # `nil` means the invitation is no longer pending (accepted, expired,
  # revoked, or the membership vanished) — the accept races resolve here.
  defp lock_pending_invitation(repo, %Membership{id: id}) do
    loaded_membership =
      Membership.Query.not_deleted()
      |> Membership.Query.by_id(id)
      |> Membership.Query.pending_invitation()
      |> Membership.Query.invitation_not_expired()
      |> Membership.Query.lock_for_update()
      |> repo.one()

    if loaded_membership,
      do: {:ok, loaded_membership},
      else: {:error, :not_found}
  end

  # -- Internal (Billing flows) -------------------------------------------
  # Account/membership reads + the one account write the Billing context
  # needs. Billing owns the plan/limit semantics; the row mechanics stay
  # here. Never exposed to LiveView/controllers/MCP.

  @doc """
  Internal — Billing seat counting: membership rows in the account.
  Counts suspended members too — suspension preserves the seat (role +
  history kept for reinstate), it doesn't free it. Removed (soft-deleted)
  members do free their seat.
  """
  def count_memberships(account_id) do
    Membership.Query.not_deleted()
    |> Membership.Query.by_account_id(account_id)
    |> Repo.aggregate(:count, :id)
  end

  # First-wins under the row lock: a concurrent checkout already linked a
  # customer — keep it (the empty changeset makes the update a no-op write).
  defp link_paddle_customer_unless_linked(
         %Account{paddle_customer_id: nil} = account,
         customer_id
       ),
       do: Account.Changeset.link_paddle_customer(account, customer_id)

  defp link_paddle_customer_unless_linked(%Account{} = account, _customer_id),
    do: Ecto.Changeset.change(account)

  @doc """
  Internal — Billing webhook resolve: the account a Paddle customer id
  belongs to, nil-or-struct (`peek` — an unknown customer_id is a meaningful
  no-match the webhook handler no-ops on).
  """
  def peek_account_by_paddle_customer_id(customer_id) when is_binary(customer_id) do
    # Deliberately `all()`, not `not_deleted()`: a tombstoned account's
    # subscription webhooks (cancellation, final invoices) must still
    # resolve so Billing can close the books on it.
    Account.Query.all()
    |> Account.Query.by_paddle_customer_id(customer_id)
    |> Repo.peek()
  end

  @doc """
  Internal — Billing: stamp the Paddle customer id after first checkout.
  First-wins under the row lock: two concurrent first-checkouts both
  create a vendor customer, but only the first write lands — the loser
  gets the winner's account back (its vendor customer stays orphaned at
  Paddle, an accepted cost; orphans bill nothing). Callers must read the
  id off the RETURNED account, not the one they minted.
  """
  def put_account_paddle_customer_id(%Account{} = account, customer_id)
      when is_binary(customer_id) do
    Account.Query.not_deleted()
    |> Account.Query.by_id(account.id)
    |> Repo.fetch_and_update(Account.Query,
      with: &link_paddle_customer_unless_linked(&1, customer_id)
    )
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
