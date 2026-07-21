defmodule Emisar.Accounts do
  @moduledoc """
  The multi-tenant boundary. Manages accounts (orgs), users, and the
  memberships that join them with a role.

  Every read API in the rest of the system is expected to scope by
  account; this context owns the slug-based lookups and signup flow.

  It also supervises the account-owned recurrent jobs (the monthly
  account-health value report).
  """
  use Supervisor
  alias Ecto.Multi
  alias Emisar.Accounts.{Account, Authorizer, Membership}
  alias Emisar.Accounts.{MembershipRunnerScope, RunnerAccess}
  alias Emisar.{ApiKeys, Audit, Auth, Crypto, Mail, Repo, Slug, SSO, Users}
  alias Emisar.Auth.Subject
  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__.Supervisor)
  end

  @impl Supervisor
  def init(_opts) do
    children = [job_module("MonthlyReports")]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp job_module(name), do: Module.safe_concat([__MODULE__, "Jobs", name])

  # -- Accounts ---------------------------------------------------------

  # Account lookups by id / slug are pre-authentication — they're how
  # `UserAuth.assign_current_account` and the public `/onboarding` path
  # resolve an account before there's a Subject to authorize with.
  # They intentionally don't take a Subject; callers operating in an
  # authenticated context should prefer `socket.assigns.current_account`
  # over re-fetching.

  @doc """
  Internal — pre-auth account lookup for `UserAuth.assign_current_account`;
  no subject exists yet.
  """
  def fetch_account_by_id(id) do
    if Repo.valid_uuid?(id) do
      Account.Query.active()
      |> Account.Query.by_id(id)
      |> Repo.fetch(Account.Query)
    else
      {:error, :not_found}
    end
  end

  @doc """
  Internal — lock the active account row (`FOR NO KEY UPDATE`) inside the CALLER's
  transaction (pass the Multi's `repo`) so concurrent per-account work serializes
  on it.

  Runners uses it as the first step of its registration / enable Multi:
  the plan-limit count is a TOCTOU otherwise (two callers both read `current <
  limit` and both insert, exceeding the ceiling).
  """
  def fetch_and_lock_account(account_id, opts \\ []) do
    if Repo.valid_uuid?(account_id) do
      repo = Keyword.get(opts, :repo, Repo)

      Account.Query.active()
      |> Account.Query.by_id(account_id)
      |> Account.Query.lock_for_update()
      |> repo.fetch(Account.Query)
    else
      {:error, :not_found}
    end
  end

  @doc """
  Internal — lock an active membership inside the caller's transaction.
  The account and membership ids are both part of the scope, and the inner
  account join rejects a membership whose account was soft-deleted. OAuth uses
  this at the consent mint so a stale session subject cannot create a key after
  access was suspended, removed, or demoted.
  """
  def fetch_and_lock_membership(account_id, membership_id, opts \\ []) do
    if Repo.valid_uuid?(account_id) and Repo.valid_uuid?(membership_id) do
      repo = Keyword.get(opts, :repo, Repo)

      Membership.Query.not_deleted()
      |> Membership.Query.not_disabled()
      |> Membership.Query.by_account_id(account_id)
      |> Membership.Query.by_id(membership_id)
      |> Membership.Query.with_joined_account()
      |> Membership.Query.lock_for_update()
      |> repo.fetch(Membership.Query)
    else
      {:error, :not_found}
    end
  end

  @doc """
  Internal — Approvals reads an account's settings to enforce them
  (e.g. the grant-lifetime cap). No subject; the approval flow
  already authorized the approver.
  """
  def fetch_account_settings(account_id) do
    if Repo.valid_uuid?(account_id) do
      Account.Query.active()
      |> Account.Query.by_id(account_id)
      |> Repo.fetch(Account.Query)
      |> case do
        {:ok, %Account{settings: settings}} -> {:ok, settings}
        {:error, :not_found} -> {:error, :not_found}
      end
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
    queryable = Account.Query.active()

    queryable =
      if Repo.valid_uuid?(id_or_slug),
        do: Account.Query.by_id(queryable, id_or_slug),
        else: Account.Query.by_slug(queryable, id_or_slug)

    Repo.fetch(queryable, Account.Query)
  end

  @doc "Internal pre-auth/support lookup that includes disabled accounts."
  def fetch_account_by_id_or_slug_including_disabled(id_or_slug) when is_binary(id_or_slug) do
    queryable = Account.Query.not_deleted()

    queryable =
      if Repo.valid_uuid?(id_or_slug),
        do: Account.Query.by_id(queryable, id_or_slug),
        else: Account.Query.by_slug(queryable, id_or_slug)

    Repo.fetch(queryable, Account.Query)
  end

  @doc """
  Internal support operation. A trusted admin or release-task boundary supplies
  the audit subject; this function is not exposed to ordinary account callers.
  The transition is idempotent and its audit row commits atomically.
  """
  def set_account_disabled_for_support(
        account_id,
        disabled?,
        reason,
        %Subject{} = subject
      )
      when is_boolean(disabled?) and is_binary(reason) and byte_size(reason) in 1..500 do
    Account.Query.not_deleted()
    |> Account.Query.by_id(account_id)
    |> Repo.fetch_and_update(Account.Query,
      with: &account_lifecycle_changeset(&1, disabled?),
      audit: &account_lifecycle_audit(&1, &2, subject, reason),
      after_commit: &after_account_lifecycle_change/2
    )
  end

  def set_account_disabled_for_support(_account_id, _disabled?, _reason, %Subject{}),
    do: {:error, :invalid_reason}

  defp account_lifecycle_changeset(%Account{disabled_at: %DateTime{}} = account, true),
    do: Ecto.Changeset.change(account)

  defp account_lifecycle_changeset(%Account{} = account, true),
    do: Account.Changeset.disable(account, DateTime.utc_now())

  defp account_lifecycle_changeset(%Account{disabled_at: nil} = account, false),
    do: Ecto.Changeset.change(account)

  defp account_lifecycle_changeset(%Account{} = account, false),
    do: Account.Changeset.enable(account)

  defp account_lifecycle_audit(account, changeset, subject, reason) do
    if Map.has_key?(changeset.changes, :disabled_at) do
      if is_nil(account.disabled_at),
        do: Audit.Events.account_enabled_by_support(subject, account, reason),
        else: Audit.Events.account_disabled_by_support(subject, account, reason)
    end
  end

  defp after_account_lifecycle_change(account, _changeset) do
    if account.disabled_at do
      :ok = broadcast_account_disabled(account.id)
      disconnect_account_members(account.id)
    else
      :ok
    end
  end

  defp disconnect_account_members(account_id) do
    Membership.Query.not_deleted()
    |> Membership.Query.by_account_id(account_id)
    |> Membership.Query.with_preloaded_user()
    |> Repo.all()
    |> Enum.each(&Auth.disconnect_and_revoke_all_sessions(&1.user))

    :ok
  end

  # -- PubSub -----------------------------------------------------------

  @doc "Subscribe to reversible account lifecycle changes."
  def subscribe_account_lifecycle(account_id),
    do: Emisar.PubSub.subscribe(account_lifecycle_topic(account_id))

  defp account_lifecycle_topic(account_id), do: "account:#{account_id}:lifecycle"

  defp broadcast_account_disabled(account_id) do
    Emisar.PubSub.broadcast(
      account_lifecycle_topic(account_id),
      {:account_disabled, account_id}
    )
  end

  @doc """
  Internal — irreversible admin erasure, invoked from a console session.
  Hard-deletes an account row and relies on the account foreign-key cascades
  to remove the account's owned records. Tombstoned accounts are included so
  a prior soft delete cannot leave data behind.
  """
  def delete_by_id(account_id) do
    if Repo.valid_uuid?(account_id) do
      Account.Query.all()
      |> Account.Query.by_id(account_id)
      |> Repo.fetch(Account.Query)
      |> case do
        {:ok, account} -> Repo.delete(account)
        {:error, :not_found} -> {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Internal — irreversible admin erasure, invoked from a console session.
  Deletes the user's sole-owner accounts, removes the user's memberships from
  other accounts through the user foreign-key cascade, then hard-deletes the
  user row. The whole operation is atomic.
  """
  def erase_user_and_owned_accounts(user_id) do
    if Repo.valid_uuid?(user_id) do
      Multi.new()
      |> Multi.run(:memberships, fn repo, _changes ->
        {:ok, active_memberships_for_user(repo, user_id)}
      end)
      |> Multi.run(:accounts, fn repo, %{memberships: memberships} ->
        erase_sole_owner_accounts(repo, memberships)
      end)
      |> Multi.run(:user, fn repo, _changes ->
        Users.delete_by_id(user_id, repo: repo)
      end)
      |> Repo.commit_multi()
      |> case do
        {:ok, %{user: user}} -> {:ok, user}
        {:error, reason} -> {:error, reason}
      end
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
  def list_accounts_for_user(%Subject{actor: %Users.User{id: user_id}}, opts \\ []) do
    Account.Query.active()
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
      Membership.Changeset.create(%{
        account_id: account.id,
        user_id: user.id,
        role: :owner,
        runner_access_mode: :all
      })
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
  changing a security setting needs `manage_security_settings` (owner +
  admin), while a rename/rebrand or a plain preference (the monthly-report
  opt-out) only needs `manage_own_account`.

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
         :ok <- Subject.ensure_in_account(subject, account.id, :unauthorized) do
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
  # manage-security permission on top of the manage-account gate already
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

  # The `settings` embed carries both security knobs and plain preferences, so
  # "is this a security change?" is FIELD-aware: only require_mfa, require_sso,
  # and max_grant_lifetime_seconds need manage_security_settings. A preference
  # like monthly_report_opt_out rides the same embed but is not security — over-
  # gating it at the most-privileged level would wrongly block low-privilege edits.
  @security_settings_fields ~w[require_mfa require_sso max_grant_lifetime_seconds]a

  defp security_setting_changed?(%Ecto.Changeset{} = changeset) do
    settings_changes = settings_changes(changeset)
    Enum.any?(@security_settings_fields, &Map.has_key?(settings_changes, &1))
  end

  # Each changed security setting gets its own audit event. The UI normally
  # sends one setting at a time, but the context also records every change from
  # a direct caller rather than silently attributing a multi-setting update to
  # only the first field.
  defp account_update_audit(
         %Account{} = account,
         %Ecto.Changeset{} = changeset,
         %Subject{} = subject
       ) do
    settings_changes = settings_changes(changeset)

    events =
      for {field, build_event} <- [
            require_mfa: &Audit.Events.account_require_mfa_set/2,
            require_sso: &Audit.Events.account_require_sso_set/2,
            max_grant_lifetime_seconds: &Audit.Events.account_max_grant_lifetime_set/2
          ],
          Map.has_key?(settings_changes, field) do
        build_event.(subject, account)
      end

    case events do
      [] -> Audit.Events.account_updated(subject, account)
      [event] -> event
      events -> events
    end
  end

  # The settings embed's own changes (the nested cast_embed changeset), or %{}
  # when only top-level account fields (name/slug) changed.
  defp settings_changes(%Ecto.Changeset{changes: %{settings: %Ecto.Changeset{changes: changes}}}),
    do: changes

  defp settings_changes(%Ecto.Changeset{}), do: %{}

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

  @doc """
  The memberships for the given `user_ids` in `account`, each preloaded with its
  user — for surfacing and acting on synced members from the SSO connection page.
  Bounded (the caller passes a known set of ids), so it returns the full list, not
  a page. Requires `view_own_account`; scoped to the account.
  Returns `{:ok, [%Membership{}]}`.
  """
  def list_memberships_for_users(%Account{id: account_id}, user_ids, %Subject{} = subject)
      when is_list(user_ids) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_own_account_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, account_id, :unauthorized) do
      memberships =
        Membership.Query.not_deleted()
        |> Membership.Query.by_account_id(account_id)
        |> Membership.Query.by_user_ids(user_ids)
        |> Membership.Query.with_preloaded_user()
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, memberships}
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

  defp active_memberships_for_user(repo, user_id) do
    Membership.Query.not_deleted()
    |> Membership.Query.by_user_id(user_id)
    |> repo.all()
  end

  defp erase_sole_owner_accounts(repo, memberships) do
    memberships
    |> Enum.uniq_by(& &1.account_id)
    |> Enum.sort_by(& &1.account_id)
    |> Enum.reduce_while({:ok, []}, fn membership, {:ok, deleted_accounts} ->
      if sole_owner?(repo, membership) do
        case delete_by_id(membership.account_id) do
          {:ok, account} -> {:cont, {:ok, [account | deleted_accounts]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      else
        {:cont, {:ok, deleted_accounts}}
      end
    end)
  end

  defp sole_owner?(repo, %Membership{account_id: account_id, role: :owner}) do
    owner_memberships =
      Membership.Query.not_deleted()
      |> Membership.Query.by_account_id(account_id)
      |> Membership.Query.by_role(:owner)

    repo.aggregate(owner_memberships, :count, :id) == 1
  end

  defp sole_owner?(_repo, %Membership{}), do: false

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
  Internal — Audit's user-event fan-out: EVERY active (not-deleted, not-suspended)
  membership the user holds, so a user-scoped security event lands one row per
  account the user belongs to (each account legitimately sees its own copy). No
  `%Subject{}` — the caller is the subject-less audit builder.
  """
  def list_active_memberships_for_user(%Users.User{id: user_id}) do
    Membership.Query.not_deleted()
    |> Membership.Query.by_user_id(user_id)
    |> Membership.Query.not_disabled()
    |> Repo.all()
  end

  @doc """
  Internal — SSO: create a membership for a JIT-provisioned user at the
  provider's `default_role`. No `%Subject{}` — the caller is the pre-auth SSO
  callback, scoped to the provider's account; composed into the SSO JIT
  `Multi` via `Multi.run`. The JIT user is always brand-new, so the
  `(account, user)` unique can't fire here.

  `active?` mirrors the SCIM `active` flag: a directory that provisions a user
  it created deactivated (`active: false`) gets a membership born suspended, so
  a "deactivated in IdP" identity never silently holds access.
  """
  # Defense in depth: `:owner` is never assignable via sync (the provider
  # changeset rejects it as a default_role too) — owner is a deliberate human
  # grant needing `manage_owners`.
  def provision_sso_membership(account_id, user_id, role, access, opts \\ [])

  def provision_sso_membership(_account_id, _user_id, :owner, %RunnerAccess{}, _opts) do
    {:error, :owner_not_assignable}
  end

  def provision_sso_membership(account_id, user_id, role, %RunnerAccess{} = access, opts) do
    active? = Keyword.get(opts, :active?, true)
    directory_managed? = Keyword.get(opts, :directory_managed?, false)
    directory_provider = Keyword.get(opts, :directory_provider)

    attrs = %{
      account_id: account_id,
      user_id: user_id,
      role: role,
      directory_managed: directory_managed?,
      runner_access_mode: access.mode,
      runner_access_directory_managed: directory_managed?,
      directory_provider_id: directory_provider_id(directory_provider, directory_managed?),
      directory_authorization_version:
        directory_provider_version(directory_provider, directory_managed?)
    }

    Multi.new()
    |> Multi.insert(:membership, sso_membership_changeset(attrs, active?))
    |> Multi.run(:runner_access, fn repo, %{membership: membership} ->
      replace_runner_access_rows(repo, membership.id, access)
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{membership: membership}} -> {:ok, membership}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sso_membership_changeset(attrs, true), do: Membership.Changeset.create(attrs)
  defp sso_membership_changeset(attrs, false), do: Membership.Changeset.create_suspended(attrs)

  defp directory_provider_id(%SSO.IdentityProvider{id: id}, true), do: id
  defp directory_provider_id(_provider, _managed?), do: nil

  defp directory_provider_version(%SSO.IdentityProvider{authorization_version: version}, true),
    do: version

  defp directory_provider_version(_provider, _managed?), do: 0

  @doc """
  Internal - current runner access for an authenticated subject. The membership
  is re-read on every call and must still be active in the subject's account.
  Missing, unbound, cross-account, or inconsistent data returns explicit none.
  """
  def runner_access_for_subject(%Subject{
        account: %Account{id: account_id},
        membership_id: membership_id
      }) do
    runner_access_for_membership(account_id, membership_id)
  end

  def runner_access_for_subject(%Subject{}), do: RunnerAccess.none()

  @doc """
  Internal - current active runner access by account and membership id. Runbook
  continuations use this before each wave; malformed identifiers fail closed.
  """
  def runner_access_for_membership(account_id, membership_id)
      when is_binary(account_id) and is_binary(membership_id) do
    if Repo.valid_uuid?(account_id) and Repo.valid_uuid?(membership_id) do
      membership =
        Membership.Query.not_deleted()
        |> Membership.Query.not_disabled()
        |> Membership.Query.by_account_id(account_id)
        |> Membership.Query.by_id(membership_id)
        |> Repo.peek()

      case membership do
        %Membership{} = membership -> load_runner_access(Repo, membership)
        nil -> RunnerAccess.none()
      end
    else
      RunnerAccess.none()
    end
  end

  def runner_access_for_membership(_account_id, _membership_id), do: RunnerAccess.none()

  @doc """
  Internal - batch runner access for already account-scoped membership rows.
  Used by Team to render explicit access without an N+1 query.
  """
  def runner_access_for_memberships(memberships) when is_list(memberships) do
    membership_by_id = Map.new(memberships, &{&1.id, &1})
    ids = Map.keys(membership_by_id)

    scopes_by_membership =
      case ids do
        [] ->
          %{}

        ids ->
          MembershipRunnerScope.Query.by_membership_ids(ids)
          |> MembershipRunnerScope.Query.ordered_by_type_and_value()
          |> Repo.all()
          |> Enum.group_by(& &1.membership_id)
      end

    Map.new(membership_by_id, fn {id, membership} ->
      access = persisted_runner_access(membership, Map.get(scopes_by_membership, id, []))
      {id, access}
    end)
  end

  @doc """
  Replace one membership's runner access atomically. The locked row enforces
  account scope, directory ownership, and live nondelegation before mode and
  normalized scopes are written with one audit event.
  """
  def update_membership_runner_access(
        %Membership{} = membership,
        %RunnerAccess{} = access,
        %Subject{} = subject
      ) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_team_permission()),
         :ok <- ensure_subject_in_account(subject, membership.account_id),
         :ok <- ensure_runner_access_grant_allowed(subject, access) do
      Multi.new()
      |> Multi.run(:target, fn repo, _changes ->
        lock_runner_access_membership(repo, membership.id, membership.account_id)
      end)
      |> Multi.run(:previous_access, fn repo, %{target: target} ->
        {:ok, load_runner_access(repo, target)}
      end)
      |> Multi.run(:runner_access_guard, fn _repo, %{target: target} ->
        with :ok <- ensure_can_modify_membership(target, subject),
             :ok <- ensure_runner_access_grant_allowed(subject, access),
             :ok <- ensure_runner_access_not_directory_managed(target) do
          {:ok, :ok}
        else
          {:error, reason} -> {:error, reason}
        end
      end)
      |> Multi.update(:membership, fn %{target: target} ->
        Membership.Changeset.update_runner_access(target, access.mode)
      end)
      |> Multi.run(:runner_access, fn repo, %{membership: updated} ->
        replace_runner_access_rows(repo, updated.id, access)
      end)
      |> Multi.run(:audit, fn repo, changes ->
        insert_runner_access_audit(repo, subject, changes, access)
      end)
      |> Repo.commit_multi(after_commit: &on_membership_runner_access_changed/1)
      |> case do
        {:ok, %{membership: updated}} -> {:ok, updated}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Internal - SSO and team configuration use the same live nondelegation check:
  a subject may grant only runner access their current active membership covers.
  """
  def ensure_runner_access_grant_allowed(%Subject{} = subject, %RunnerAccess{} = access) do
    if RunnerAccess.covers?(runner_access_for_subject(subject), access),
      do: :ok,
      else: {:error, :runner_access_exceeds_subject}
  end

  @doc "Internal - reject individual runner grants that do not name live runners in the account."
  def validate_runner_access_for_account(account_id, %RunnerAccess{runner_ids: runner_ids})
      when is_binary(account_id) do
    cond do
      runner_ids == [] ->
        :ok

      not Repo.valid_uuid?(account_id) ->
        {:error, :invalid_runner_access}

      true ->
        query = """
        SELECT NOT EXISTS (
          SELECT 1
          FROM unnest($1::uuid[]) AS requested(id)
          WHERE NOT EXISTS (
            SELECT 1
            FROM runners
            WHERE runners.account_id = $2
              AND runners.id = requested.id
              AND runners.deleted_at IS NULL
          )
        )
        """

        dumped_runner_ids = Enum.map(runner_ids, &Ecto.UUID.dump!/1)

        case Ecto.Adapters.SQL.query(Repo, query, [
               dumped_runner_ids,
               Ecto.UUID.dump!(account_id)
             ]) do
          {:ok, %{rows: [[true]]}} -> :ok
          {:ok, %{rows: [[false]]}} -> {:error, :invalid_runner_access}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def validate_runner_access_for_account(_account_id, %RunnerAccess{}),
    do: {:error, :invalid_runner_access}

  defp ensure_runner_access_not_directory_managed(%Membership{
         runner_access_directory_managed: true
       }),
       do: {:error, :runner_access_managed_by_directory}

  defp ensure_runner_access_not_directory_managed(%Membership{}), do: :ok

  defp lock_runner_access_membership(repo, membership_id, account_id) do
    Membership.Query.not_deleted()
    |> Membership.Query.by_account_id(account_id)
    |> Membership.Query.by_id(membership_id)
    |> Membership.Query.lock_for_update()
    |> repo.fetch(Membership.Query)
  end

  defp load_runner_access(repo, %Membership{} = membership) do
    scopes =
      MembershipRunnerScope.Query.by_membership_id(membership.id)
      |> MembershipRunnerScope.Query.ordered_by_type_and_value()
      |> repo.all()

    persisted_runner_access(membership, scopes)
  end

  defp persisted_runner_access(
         %Membership{directory_authorization_pending_version: version},
         _scopes
       )
       when is_integer(version),
       do: RunnerAccess.none()

  defp persisted_runner_access(%Membership{} = membership, scopes) do
    case RunnerAccess.from_fields(membership, scopes) do
      {:ok, access} -> access
      {:error, _reason} -> RunnerAccess.none()
    end
  end

  defp replace_runner_access_rows(repo, membership_id, %RunnerAccess{} = access) do
    with :ok <- validate_runner_access_ids(repo, membership_id, access) do
      do_replace_runner_access_rows(repo, membership_id, access)
    end
  end

  defp do_replace_runner_access_rows(repo, membership_id, %RunnerAccess{} = access) do
    {:ok, _result} =
      Ecto.Adapters.SQL.query(
        repo,
        "SELECT set_config('emisar.runner_access_write', 'enabled', true)",
        []
      )

    MembershipRunnerScope.Query.by_membership_id(membership_id)
    |> repo.delete_all()

    now = DateTime.utc_now()

    rows =
      Enum.map(RunnerAccess.scope_tuples(access), fn {scope_type, scope_value} ->
        %{
          id: Repo.generate_id(),
          membership_id: membership_id,
          scope_type: scope_type,
          scope_value: scope_value,
          inserted_at: now
        }
      end)

    repo.insert_all(MembershipRunnerScope, rows)

    {:ok, _result} =
      Ecto.Adapters.SQL.query(
        repo,
        "SELECT set_config('emisar.runner_access_write', 'disabled', true)",
        []
      )

    {:ok, access}
  end

  defp validate_runner_access_ids(_repo, _membership_id, %RunnerAccess{runner_ids: []}), do: :ok

  defp validate_runner_access_ids(repo, membership_id, %RunnerAccess{runner_ids: runner_ids}) do
    query = """
    SELECT NOT EXISTS (
      SELECT 1
      FROM unnest($1::uuid[]) AS requested(id)
      WHERE NOT EXISTS (
        SELECT 1
        FROM account_memberships AS memberships
        JOIN runners ON runners.account_id = memberships.account_id
        WHERE memberships.id = $2
          AND runners.id = requested.id
          AND runners.deleted_at IS NULL
      )
    )
    """

    dumped_runner_ids = Enum.map(runner_ids, &Ecto.UUID.dump!/1)

    case Ecto.Adapters.SQL.query(repo, query, [dumped_runner_ids, Ecto.UUID.dump!(membership_id)]) do
      {:ok, %{rows: [[true]]}} -> :ok
      {:ok, %{rows: [[false]]}} -> {:error, :invalid_runner_access}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_runner_access_audit(repo, subject, changes, access) do
    previous_access = changes.previous_access

    if previous_access == access do
      {:ok, nil}
    else
      Audit.Events.membership_runner_access_changed(
        subject,
        changes.target,
        previous_access,
        access
      )
      |> repo.insert()
    end
  end

  defp on_membership_runner_access_changed(%{
         membership: membership,
         previous_access: previous_access,
         runner_access: access
       }) do
    broadcast_membership_runner_access_changed(membership)

    if RunnerAccess.covers?(previous_access, access) and
         not RunnerAccess.covers?(access, previous_access) do
      refresh_member_sessions(membership)
    else
      :ok
    end
  end

  defp broadcast_membership_runner_access_changed(%Membership{} = membership) do
    Emisar.PubSub.broadcast(
      account_team_topic(membership.account_id),
      {:list_changed, :team, "membership.runner_access_changed", membership.user_id}
    )
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

  @doc "Internal - lock a run initiator's current active membership in the caller's transaction."
  def fetch_and_lock_active_membership(repo, account_id, membership_id)
      when is_binary(account_id) and is_binary(membership_id) do
    Membership.Query.not_deleted()
    |> Membership.Query.not_disabled()
    |> Membership.Query.by_account_id(account_id)
    |> Membership.Query.by_id(membership_id)
    |> Membership.Query.lock_for_update()
    |> repo.fetch(Membership.Query)
  end

  def fetch_and_lock_active_membership(_repo, _account_id, _membership_id),
    do: {:error, :not_found}

  @doc "Internal - explicit access for a membership row already locked by a caller transaction."
  def runner_access_for_locked_membership(repo, %Membership{} = membership),
    do: load_runner_access(repo, membership)

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

  A member whose role a directory sync owns (`directory_managed` — SCIM recomputes
  it on every sync, so a manual change silently reverts) is rejected with
  `{:error, :role_managed_by_directory}`. The flag lives on the membership (set by
  the sync write path), so the domain enforces this itself — no caller-supplied
  hint, no UI trust.
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
          # The guards judge the row's CURRENT state under the lock — the caller's
          # struct is a stale socket snapshot. `directory_managed` is judged here
          # too, so a stale UI or crafted event can't slip a synced-role change past.
          with :ok <- ensure_role_not_directory_managed(loaded_membership),
               :ok <- ensure_role_change_allowed(loaded_membership, new_role, subject),
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

  defp reduced_permissions?(old_role, new_role) do
    not MapSet.subset?(Auth.Permissions.for_role(old_role), Auth.Permissions.for_role(new_role))
  end

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

  defp broadcast_membership_invitation_resent(%Membership{} = membership) do
    Emisar.PubSub.broadcast(
      account_team_topic(membership.account_id),
      {:list_changed, :team, "membership.invitation_resent", membership.user_id}
    )
  end

  defp broadcast_membership_removed(%Membership{} = membership) do
    Emisar.PubSub.broadcast(
      account_team_topic(membership.account_id),
      {:list_changed, :team, "membership.removed", membership.user_id}
    )
  end

  # A directory (SCIM) sync owns the role of a synced member — it recomputes it on
  # every push (group→role mapping, else the provider default), so a manual change
  # silently reverts. The `directory_managed` flag on the membership records that
  # (set by the sync write path, cleared when SCIM is disabled), so the domain
  # refuses here off the LOCKED row — no UI hint, no context cycle into `SSO`.
  defp ensure_role_not_directory_managed(%Membership{directory_managed: true}),
    do: {:error, :role_managed_by_directory}

  defp ensure_role_not_directory_managed(%Membership{}), do: :ok

  # A member the directory (SCIM) has deactivated (`directory_suspended`, set by the
  # SCIM deprovision write path) must stay suspended — reinstating them in emisar
  # would grant access the IdP revoked. Reactivation is the IdP's to make (its
  # `active: true` re-sync reinstates them). Domain-owned: judged on the locked
  # row, no UI hint, no context cycle into `SSO`.
  defp ensure_not_deactivated_in_idp(%Membership{directory_suspended: true}),
    do: {:error, :deactivated_in_idp}

  defp ensure_not_deactivated_in_idp(%Membership{}), do: :ok

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
        Logger.warning("membership_user_missing",
          user_id: membership.user_id,
          membership_id: membership.id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  @doc """
  Re-enable a previously suspended member. Same authorization shape as suspend.

  A member the directory (SCIM) has deactivated (`directory_suspended` — set by the
  SCIM deprovision write path) is refused with `{:error, :deactivated_in_idp}`:
  reinstating them would grant emisar access the IdP revoked. Reactivation must
  happen in the IdP (its `active: true` re-sync reinstates via
  `sync_reinstate_membership`). The flag lives on the membership, so the domain
  enforces this itself off the locked row — no caller-supplied hint, no cycle.
  """
  def reinstate_membership(%Membership{} = membership, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_team_permission()),
         :ok <- ensure_subject_in_account(subject, membership.account_id) do
      Membership.Query.not_deleted()
      |> Membership.Query.by_id(membership.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Membership.Query,
        with: fn loaded_membership ->
          # The guards judge the row's CURRENT state under the lock — the caller's
          # struct is a stale socket snapshot. `directory_suspended` is judged here
          # too, so a stale UI or crafted event can't reinstate an IdP-revoked member.
          with :ok <- ensure_not_deactivated_in_idp(loaded_membership),
               :ok <- ensure_can_modify_membership(loaded_membership, subject) do
            Membership.Changeset.reinstate(loaded_membership)
          else
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
  lock out the account's last owner (§9 N5). An already-suspended member is a
  no-op `{:ok, membership}` — in particular a MANUAL suspension keeps manual
  provenance, so the IdP's later reactivate cannot lift it. Returns
  `{:ok, membership} | {:error, :last_owner | :not_found}`.
  """
  def sync_suspend_membership(%Membership{} = membership, %SSO.IdentityProvider{} = provider) do
    Membership.Query.not_deleted()
    |> Membership.Query.by_id(membership.id)
    |> Repo.fetch_and_update(Membership.Query,
      with: fn loaded_membership ->
        # Guards judge the locked row: it must live in the provider's account
        # (the directory-sync authz boundary), and a deprovision can never lock
        # out the account's last owner. An ALREADY-suspended row is a no-op —
        # crucially, the directory never takes ownership of a MANUAL break-glass
        # suspend (that would let its later reactivate lift a hold an operator
        # placed on purpose).
        with :ok <- ensure_membership_in_provider_account(loaded_membership, provider),
             :ok <- ensure_not_suspended(loaded_membership),
             :ok <- ensure_not_last_active_owner(loaded_membership) do
          Membership.Changeset.sync_suspend(loaded_membership)
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
    |> noop_as_ok()
  end

  # `{:noop, row}` rides fetch_and_update's abort channel (any non-changeset
  # `:with` return becomes `{:error, value}`) so an idempotent sync transition
  # commits nothing — no UPDATE, no audit row, no after_commit side effects —
  # yet still answers `{:ok, membership}` to the SCIM caller.
  defp noop_as_ok({:error, {:noop, %Membership{} = membership}}), do: {:ok, membership}
  defp noop_as_ok(other), do: other

  defp ensure_not_suspended(%Membership{disabled_at: nil}), do: :ok
  defp ensure_not_suspended(%Membership{} = membership), do: {:error, {:noop, membership}}

  @doc """
  Internal — directory sync: reinstate a member the IdP re-provisioned
  (SCIM `active:true`). No `%Subject{}` — see `sync_suspend_membership/2`.
  Clears `disabled_at` under the row lock + broadcasts — but ONLY a
  `directory_suspended` row: a manually-suspended member is a no-op
  `{:ok, membership}` that stays suspended (the local break-glass hold wins;
  an operator lifts it via `reinstate_membership/2`). Returns
  `{:ok, membership} | {:error, :not_found}`.
  """
  def sync_reinstate_membership(%Membership{} = membership, %SSO.IdentityProvider{} = provider) do
    Membership.Query.not_deleted()
    |> Membership.Query.by_id(membership.id)
    |> Repo.fetch_and_update(Membership.Query,
      with: fn loaded_membership ->
        # The locked row must live in the provider's account before we write —
        # and the directory only lifts suspensions IT owns (`directory_suspended`).
        # A MANUAL suspension is a break-glass hold: the IdP re-activating the
        # user must not reinstate them (no-op; the operator lifts it locally).
        with :ok <- ensure_membership_in_provider_account(loaded_membership, provider),
             :ok <- ensure_directory_suspended(loaded_membership) do
          Membership.Changeset.reinstate(loaded_membership)
        else
          {:error, reason} -> reason
        end
      end,
      audit: &Audit.Events.membership_reprovisioned_via_scim(&1, provider),
      after_commit: &broadcast_membership_reinstated/1
    )
    |> noop_as_ok()
  end

  defp ensure_directory_suspended(%Membership{directory_suspended: true}), do: :ok
  defp ensure_directory_suspended(%Membership{} = membership), do: {:error, {:noop, membership}}

  @doc """
  Internal - SCIM's one locked authorization write. Role and runner access are
  recomputed from the same directory snapshot, persisted in one transaction,
  and marked directory-managed together. The provider account is the authority.
  """
  def sync_set_membership_authorization(
        %Membership{} = membership,
        role,
        %RunnerAccess{} = access,
        %SSO.IdentityProvider{} = provider
      ) do
    Multi.new()
    |> Multi.run(:target, fn repo, _changes ->
      lock_runner_access_membership(repo, membership.id, provider.account_id)
    end)
    |> Multi.run(:previous_access, fn repo, %{target: target} ->
      {:ok, load_runner_access(repo, target)}
    end)
    |> Multi.run(:authorization_guard, fn _repo, %{target: target} ->
      with :ok <- ensure_membership_in_provider_account(target, provider),
           :ok <- ensure_directory_provider_matches(target, provider),
           :ok <- ensure_current_authorization_version(target, provider),
           :ok <- ensure_synced_role_transition(target, role) do
        {:ok, :ok}
      end
    end)
    |> Multi.update(:membership, fn %{target: target} ->
      if target.role == :owner do
        Membership.Changeset.sync_runner_authorization(
          target,
          access.mode,
          provider.id,
          provider.authorization_version
        )
      else
        Membership.Changeset.sync_authorization(
          target,
          role,
          access.mode,
          provider.id,
          provider.authorization_version
        )
      end
    end)
    |> Multi.run(:runner_access, fn repo, %{membership: updated} ->
      replace_runner_access_rows(repo, updated.id, access)
    end)
    |> Multi.run(:role_audit, fn repo, changes ->
      insert_synced_role_audit(repo, provider, role, changes)
    end)
    |> Multi.run(:runner_access_audit, fn repo, changes ->
      insert_synced_runner_access_audit(repo, provider, access, changes)
    end)
    |> Repo.commit_multi(after_commit: &on_membership_authorization_synced/1)
    |> case do
      {:ok, %{membership: updated}} -> {:ok, updated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_synced_role_audit(
         repo,
         provider,
         _role,
         %{target: target, membership: membership}
       ) do
    if target.role == membership.role do
      {:ok, nil}
    else
      target
      |> Audit.Events.membership_role_synced_via_scim(provider, membership.role)
      |> repo.insert()
    end
  end

  defp insert_synced_runner_access_audit(
         repo,
         provider,
         access,
         %{target: target, previous_access: previous_access}
       ) do
    if previous_access == access do
      {:ok, nil}
    else
      target
      |> Audit.Events.membership_runner_access_synced_via_scim(
        provider,
        previous_access,
        access
      )
      |> repo.insert()
    end
  end

  defp on_membership_authorization_synced(%{
         target: previous_membership,
         membership: membership,
         previous_access: previous_access,
         runner_access: access
       }) do
    broadcast_membership_role_changed(membership)

    if is_integer(previous_membership.directory_authorization_pending_version) do
      refresh_member_sessions(membership)
    else
      maybe_refresh_reduced_member_sessions(previous_membership.role, membership)

      if RunnerAccess.covers?(previous_access, access) and
           not RunnerAccess.covers?(access, previous_access) do
        refresh_member_sessions(membership)
      else
        :ok
      end
    end
  end

  @doc """
  Internal — directory sync: set a member's role from their mapped IdP groups
  (Slice 2b). No `%Subject{}` — the SCIM bearer's provider-scope is the
  authorization, validated at the web boundary; the `provider` is threaded
  only to attribute the audit to the directory.

  Defense in depth even though group→role mappings already exclude `:owner`
  (decision 7): the `:with` **refuses `:owner`** under the lock, and it **never
  demotes the account's last active owner** (`ensure_not_last_active_owner` when
  the CURRENT role is `:owner` and the new role isn't — §9 N5). Marks the role
  `directory_managed` (the domain-owned synced-role lock). Idempotent: when the
  role AND the directory-managed mark already match, returns `{:ok, membership}`
  with no write or audit — but a role that matches while still unmarked falls
  through so the mark gets set. Returns `{:ok, membership} | {:error,
  :owner_not_assignable | :last_owner | :not_found | %Ecto.Changeset{}}`.
  """
  def sync_set_membership_role(
        %Membership{account_id: account_id, role: role, directory_managed: true} = membership,
        role,
        %SSO.IdentityProvider{account_id: account_id}
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
          Membership.Changeset.sync_role(loaded_membership, role)
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

  @doc """
  Internal — SCIM disable: return role control to operators by clearing the
  `directory_managed` flag on the memberships of `user_ids` (a provider's synced
  members) in `account_id`. No `%Subject{}` — the SSO caller is already authorized
  by the provider's account scope. Returns `{count, nil}`.
  """
  def clear_directory_managed_for_users(account_id, user_ids)
      when is_binary(account_id) and is_list(user_ids) do
    Membership.Query.not_deleted()
    |> Membership.Query.by_account_id(account_id)
    |> Membership.Query.by_user_ids(user_ids)
    |> Repo.update_all(
      set: [
        directory_managed: false,
        runner_access_directory_managed: false,
        directory_provider_id: nil,
        directory_authorization_pending_version: nil,
        updated_at: DateTime.utc_now()
      ]
    )
  end

  # Directory sync can never grant owner — owner stays a deliberate human
  # assignment (decision 7). The group→role mapping changeset already excludes
  # it; this is the write-path backstop.
  defp ensure_sync_role_assignable(:owner), do: {:error, :owner_not_assignable}
  defp ensure_sync_role_assignable(_role), do: :ok

  defp ensure_synced_role_transition(%Membership{role: :owner}, _role), do: :ok

  defp ensure_synced_role_transition(%Membership{} = membership, role) do
    with :ok <- ensure_sync_role_assignable(role) do
      ensure_demotion_keeps_an_owner(membership, role)
    end
  end

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

  defp ensure_directory_provider_matches(
         %Membership{directory_provider_id: nil},
         %SSO.IdentityProvider{}
       ),
       do: :ok

  defp ensure_directory_provider_matches(
         %Membership{directory_provider_id: provider_id},
         %SSO.IdentityProvider{id: provider_id}
       ),
       do: :ok

  defp ensure_directory_provider_matches(%Membership{}, %SSO.IdentityProvider{}),
    do: {:error, :directory_authorization_provider_conflict}

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

  defp ensure_current_authorization_version(
         %Membership{directory_authorization_pending_version: pending},
         %SSO.IdentityProvider{authorization_version: version}
       )
       when is_integer(pending) and pending > version,
       do: {:error, :stale_authorization_version}

  defp ensure_current_authorization_version(%Membership{}, %SSO.IdentityProvider{}), do: :ok

  @doc "Internal - atomically mark a provider's affected memberships fail-closed until reconciliation."
  def mark_directory_authorization_pending(
        repo,
        account_id,
        provider_id,
        user_ids,
        version
      )
      when is_list(user_ids) and is_integer(version) do
    Membership.Query.not_deleted()
    |> Membership.Query.by_account_id(account_id)
    |> Membership.Query.by_user_ids(user_ids)
    |> Membership.Query.by_directory_provider_or_unmanaged(provider_id)
    |> repo.update_all(
      set: [
        runner_access_directory_managed: true,
        directory_provider_id: provider_id,
        directory_authorization_pending_version: version,
        updated_at: DateTime.utc_now()
      ]
    )

    {:ok, version}
  end

  @doc "Internal - bounded durable directory authorization work for the SSO retry job."
  def list_pending_directory_authorizations(limit) when is_integer(limit) and limit > 0 do
    Membership.Query.not_deleted()
    |> Membership.Query.authorization_sync_pending()
    |> Membership.Query.limit_to(limit)
    |> Repo.all()
  end

  @doc "Internal - remount one member's live sessions around a fail-closed directory transition."
  def refresh_directory_authorization_sessions(%Membership{} = membership),
    do: refresh_member_sessions(membership)

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

  A directory-synced member (a live identity under a SCIM-enabled provider)
  is refused with `{:error, :directory_managed_profile}` — the IdP owns their
  profile and the next sync would overwrite the edit anyway.

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
      |> Multi.run(:profile_ownership, fn _repo, %{target: loaded_membership} ->
        # A directory-synced member's profile is the IdP's (same scim_enabled
        # boundary as the role lock) — an edit here would just fight the sync.
        if SSO.user_profile_directory_managed?(
             loaded_membership.account_id,
             loaded_membership.user_id
           ) do
          {:error, :directory_managed_profile}
        else
          {:ok, :editable}
        end
      end)
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
          # A removed member's mounted session still carries its old Subject
          # until it remounts. Disconnect + revoke it after the delete commits,
          # alongside the API keys that would otherwise keep dispatching.
          &disconnect_user_sessions/1,
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
  def invite_user_to_account(
        email,
        role,
        %RunnerAccess{} = access,
        %Subject{account: %Account{id: account_id}} = subject
      )
      when is_binary(email) and is_binary(role) do
    # Team seats are intentionally NOT capped (no Billing.check_limit(:members)
    # here, unlike the runner cap): giving away collaboration is a deliberate
    # growth lever — Free's members_limit + the Team meter are aspirational, not
    # gates. Revisit only if seat-based pricing lands. (PENDING_DECISIONS, 2026-06-14.)
    with :ok <- ensure_invite_permitted(role, subject),
         :ok <- ensure_runner_access_grant_allowed(subject, access) do
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
          runner_access_mode: access.mode,
          invited_by_id: subject.actor.id,
          invitation_token_digest: token_digest
        })
      end)
      |> Multi.run(:runner_access, fn repo, %{membership: membership} ->
        replace_runner_access_rows(repo, membership.id, access)
      end)
      |> Multi.insert(:audit, fn %{user: user} ->
        Audit.Events.user_invited(subject, user, role, access)
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

  @doc """
  Resends a pending account invitation. Requires `invite` on memberships,
  role coverage for the invitee's current role, and same-account scope.

  Returns `{:ok, %{membership: m, user: u, invitation_token: token}}` or
  `{:error, :not_found | :unauthorized | :insufficient_privileges | %Ecto.Changeset{}}`.
  """
  def resend_account_invitation(%Membership{} = membership, %Subject{} = subject) do
    with :ok <- ensure_invite_permitted(membership.role, subject),
         :ok <- ensure_subject_in_account(subject, membership.account_id) do
      {token, token_digest} = Crypto.user_invite_token()

      Membership.Query.not_deleted()
      |> Membership.Query.by_id(membership.id)
      |> Membership.Query.pending_invitation()
      |> Membership.Query.not_disabled()
      |> Membership.Query.with_preloaded_user()
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Membership.Query,
        with: fn loaded_membership ->
          case ensure_invite_permitted(loaded_membership.role, subject) do
            :ok -> Membership.Changeset.resend_invitation(loaded_membership, token_digest)
            {:error, reason} -> reason
          end
        end,
        audit: fn updated ->
          Audit.Events.user_invited(
            subject,
            updated.user,
            updated.role,
            load_runner_access(Repo, updated)
          )
        end,
        after_commit: &broadcast_membership_invitation_resent/1
      )
      |> case do
        {:ok, %Membership{user: %Users.User{} = user} = updated} ->
          {:ok, %{membership: updated, user: user, invitation_token: token}}

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
  with the requested preloads, `{:error, :expired}` for a real pending
  invitation past its window (the bearer holds the emailed token, so naming
  the state is not an enumeration oracle), or `{:error, :not_found}` for
  everything else — garbage, revoked, and accepted-then-burned tokens are
  deliberately indistinguishable (acceptance clears the digest).

  Options: `preload:` — associations the caller renders (`:account`,
  `:user`); omit when only the row itself is needed.
  """
  def fetch_invitation_by_token(token, opts \\ [])

  def fetch_invitation_by_token(token, opts) when is_binary(token) and byte_size(token) > 0 do
    {preloads, _opts} = Keyword.pop(opts, :preload, [])
    digest = Crypto.user_invite_token_digest(token)

    queryable =
      Membership.Query.not_deleted()
      |> Membership.Query.by_invitation_token_digest(digest)
      |> Membership.Query.pending_invitation()
      |> Membership.Query.invitation_not_expired()
      |> Membership.Query.with_joined_account()
      |> apply_membership_preloads(preloads)

    case Repo.fetch(queryable, Membership.Query) do
      {:ok, membership} -> {:ok, membership}
      {:error, :not_found} -> classify_dead_invitation(digest)
    end
  end

  def fetch_invitation_by_token(_, _opts), do: {:error, :not_found}

  # The happy-path fetch above missed: tell a lapsed-but-real pending invitation
  # apart from a token that resolves to nothing actionable.
  defp classify_dead_invitation(digest) do
    queryable =
      Membership.Query.not_deleted()
      |> Membership.Query.by_invitation_token_digest(digest)
      |> Membership.Query.with_joined_account()

    case Repo.peek(queryable) do
      %Membership{invitation_accepted_at: nil} -> {:error, :expired}
      _ -> {:error, :not_found}
    end
  end

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
    Multi.new()
    |> put_active_account_lock(membership.account_id, :active_account)
    |> Multi.run(:membership, fn repo, _changes ->
      lock_pending_invitation(repo, membership)
    end)
    |> Multi.update(:accepted, fn %{membership: membership} ->
      Membership.Changeset.accept_invitation(membership)
    end)
    |> Multi.insert(:audit, fn %{accepted: membership} ->
      Audit.Events.membership_invitation_accepted(membership)
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{accepted: membership}} -> {:ok, membership}
      {:error, reason} -> {:error, reason}
    end
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
    |> put_active_account_lock(membership.account_id, :active_account)
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

  defp put_active_account_lock(multi, account_id, key) do
    Multi.run(multi, key, fn repo, _changes ->
      fetch_and_lock_account(account_id, repo: repo)
    end)
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

  @doc """
  Internal — system sweeps that must include tombstoned accounts. Returns a
  bounded id-ordered page and accepts `:limit` plus optional `:after_account_id`.
  """
  def list_accounts_for_system_sweep(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    Account.Query.all()
    |> after_system_sweep_account(Keyword.get(opts, :after_account_id))
    |> Account.Query.ordered_by_id()
    |> Account.Query.limit_to(limit)
    |> Repo.all()
  end

  defp after_system_sweep_account(queryable, id) when is_binary(id),
    do: Account.Query.after_id(queryable, id)

  defp after_system_sweep_account(queryable, _id), do: queryable

  @doc """
  Internal — monthly report job: a bounded, id-ordered page of non-deleted
  accounts whose value report is due at `cutoff` (never sent, or sent in an
  earlier month). Accepts `:limit` plus optional `:after_account_id` for keyset
  pagination — stamping a row doesn't move its id, so paging stays stable as the
  sweep stamps as it goes.
  """
  def list_accounts_due_for_report(%DateTime{} = cutoff, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    Account.Query.not_deleted()
    |> Account.Query.due_for_report(cutoff)
    |> after_report_account(Keyword.get(opts, :after_account_id))
    |> Account.Query.ordered_by_id()
    |> Account.Query.limit_to(limit)
    |> Repo.all()
  end

  defp after_report_account(queryable, id) when is_binary(id),
    do: Account.Query.after_id(queryable, id)

  defp after_report_account(queryable, _id), do: queryable

  @doc """
  Internal — monthly report job: stamp `last_report_sent_at = now` under a row
  lock, but only if the account is still due at `cutoff`. A repeated or
  concurrent pass that already stamped it this month gets
  `{:error, :already_reported}` so the report can't go out twice. Returns
  `{:ok, account}` on the winning stamp.
  """
  def mark_account_report_sent(%Account{} = account, %DateTime{} = cutoff) do
    query =
      Account.Query.not_deleted()
      |> Account.Query.by_id(account.id)

    Repo.fetch_and_update(query, Account.Query, with: &stamp_report_if_due(&1, cutoff))
  end

  defp stamp_report_if_due(%Account{} = loaded_account, cutoff) do
    # A non-changeset return aborts `fetch_and_update` as `{:error, that_value}`,
    # so return the bare reason (not a wrapped tuple) to get `{:error, :already_reported}`.
    if report_due?(loaded_account, cutoff),
      do: Account.Changeset.mark_report_sent(loaded_account),
      else: :already_reported
  end

  defp report_due?(%Account{last_report_sent_at: nil}, _cutoff), do: true

  defp report_due?(%Account{last_report_sent_at: sent_at}, cutoff),
    do: DateTime.compare(sent_at, cutoff) == :lt

  @doc """
  Internal — Billing job: accounts whose Paddle customer is missing or
  stale. The caller supplies keyword opts:
  `:limit` and optional `:after_account_id`.
  """
  def list_paddle_customer_sync_accounts(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    Account.Query.not_deleted()
    |> Account.Query.needing_paddle_customer_sync()
    |> after_paddle_sync_account(Keyword.get(opts, :after_account_id))
    |> Account.Query.ordered_by_id()
    |> Account.Query.limit_to(limit)
    |> Repo.all()
  end

  defp after_paddle_sync_account(queryable, id) when is_binary(id),
    do: Account.Query.after_id(queryable, id)

  defp after_paddle_sync_account(queryable, _id), do: queryable

  @doc """
  Internal — Billing customer sync: load the account and the stable billing
  owner. The current billing-contact user is kept while they remain an active
  owner with a confirmed email; only then do we fall back to the earliest active
  confirmed owner.
  """
  def fetch_paddle_customer_sync_target(account_id) do
    if Repo.valid_uuid?(account_id) do
      account_query =
        Account.Query.not_deleted()
        |> Account.Query.by_id(account_id)

      with {:ok, account} <- Repo.fetch(account_query, Account.Query),
           {:ok, owner} <- fetch_stable_billing_owner(account) do
        {:ok, %{account: account, owner: owner}}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Internal — monthly report job: the single stable, active, confirmed owner to
  send the account's value report to, or `{:error, :no_recipient}` when none
  qualifies. Same "stable billing owner" selection the Paddle customer sync uses.
  """
  def fetch_account_report_recipient(%Account{} = account) do
    case fetch_stable_billing_owner(account) do
      {:ok, %Users.User{} = user} -> {:ok, user}
      {:error, :no_billing_contact} -> {:error, :no_recipient}
    end
  end

  @doc """
  Internal — pre-auth: resolve the account a monthly-report unsubscribe token
  addresses, for the confirm page. Read-only; the signed token IS the
  authorization. `{:error, :invalid}` on a forged/mangled token or a deleted
  account.
  """
  def fetch_account_for_report_unsubscribe(token) when is_binary(token) do
    with {:ok, account_id} <- Crypto.verify_monthly_report_unsubscribe_token(token) do
      queryable = Account.Query.not_deleted() |> Account.Query.by_id(account_id)

      case Repo.fetch(queryable, Account.Query) do
        {:ok, %Account{} = account} -> {:ok, account}
        {:error, :not_found} -> {:error, :invalid}
      end
    end
  end

  @doc """
  Internal — pre-auth: flip `monthly_report_opt_out` on via the signed token in
  the report email's `List-Unsubscribe` link. The token binds one account id and
  is unforgeable, so it IS the authorization (no subject) — the emailed-link
  analog of the SCIM / magic-link pre-auth paths. Idempotent. `{:error, :invalid}`
  on a forged token or deleted account.
  """
  def unsubscribe_from_monthly_report(token) when is_binary(token) do
    with {:ok, %Account{} = account} <- fetch_account_for_report_unsubscribe(token) do
      Account.Query.not_deleted()
      |> Account.Query.by_id(account.id)
      |> Repo.fetch_and_update(Account.Query,
        with: &Account.Changeset.update(&1, %{settings: %{monthly_report_opt_out: true}})
      )
    end
  end

  defp fetch_stable_billing_owner(%Account{paddle_billing_contact_user_id: user_id} = account)
       when is_binary(user_id) do
    case fetch_active_owner_user(account.id, user_id) do
      {:ok, owner} -> {:ok, owner}
      {:error, :not_found} -> fetch_first_active_owner_user(account.id)
    end
  end

  defp fetch_stable_billing_owner(%Account{} = account) do
    fetch_first_active_owner_user(account.id)
  end

  defp fetch_first_active_owner_user(account_id) do
    result =
      Membership.Query.not_deleted()
      |> Membership.Query.not_disabled()
      |> Membership.Query.by_account_id(account_id)
      |> Membership.Query.by_role(:owner)
      |> Membership.Query.with_confirmed_user_email()
      |> Membership.Query.with_preloaded_user()
      |> Membership.Query.oldest()
      |> Repo.fetch(Membership.Query)
      |> owner_user_result()

    case result do
      {:ok, owner} -> {:ok, owner}
      {:error, :not_found} -> {:error, :no_billing_contact}
    end
  end

  defp fetch_active_owner_user(account_id, user_id) do
    Membership.Query.not_deleted()
    |> Membership.Query.not_disabled()
    |> Membership.Query.by_account_id(account_id)
    |> Membership.Query.by_user_id(user_id)
    |> Membership.Query.by_role(:owner)
    |> Membership.Query.with_confirmed_user_email()
    |> Membership.Query.with_preloaded_user()
    |> Repo.fetch(Membership.Query)
    |> owner_user_result()
  end

  defp owner_user_result({:ok, %Membership{user: %Users.User{} = user}}), do: {:ok, user}
  defp owner_user_result({:error, :not_found}), do: {:error, :not_found}

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
  Internal — Billing: stamp a successful Paddle customer sync.
  First-wins under the row lock: two concurrent first syncs may both mint
  a vendor customer, but only the first customer id lands. A loser gets the
  winner's account back without marking it clean; Billing then updates the
  winning Paddle customer and calls this again with the stored id.
  """
  def put_account_paddle_customer_sync(
        %Account{} = account,
        customer_id,
        billing_contact_user_id
      )
      when is_binary(customer_id) and is_binary(billing_contact_user_id) do
    Account.Query.not_deleted()
    |> Account.Query.by_id(account.id)
    |> Repo.fetch_and_update(Account.Query,
      with: &sync_paddle_customer_if_current(&1, customer_id, billing_contact_user_id)
    )
  end

  defp sync_paddle_customer_if_current(
         %Account{paddle_customer_id: nil} = account,
         customer_id,
         billing_contact_user_id
       ),
       do: Account.Changeset.sync_paddle_customer(account, customer_id, billing_contact_user_id)

  defp sync_paddle_customer_if_current(
         %Account{paddle_customer_id: existing_customer_id} = account,
         customer_id,
         billing_contact_user_id
       )
       when existing_customer_id == customer_id,
       do: Account.Changeset.sync_paddle_customer(account, customer_id, billing_contact_user_id)

  defp sync_paddle_customer_if_current(%Account{} = account, _customer_id, _owner_id),
    do: Ecto.Changeset.change(account)

  # -- Authorization ----------------------------------------------------

  @doc "Whether `subject` may manage team memberships (admin+)."
  def subject_can_manage_team?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.manage_team_permission())

  @doc """
  Whether `subject` may change the account itself — its name and non-security
  preferences like the monthly-report opt-out (owner or admin).
  """
  def subject_can_manage_account?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.manage_own_account_permission())

  @doc """
  Whether `subject` may change account security settings such as MFA
  enforcement (owner or admin).
  """
  def subject_can_manage_account_security?(%Subject{} = subject) do
    Auth.Authorizer.has_permission?(subject, Authorizer.manage_security_settings_permission())
  end
end
