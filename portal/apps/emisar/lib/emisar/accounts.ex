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
  alias Emisar.Accounts.{Account, Authorizer, InvitationInput, Membership}
  alias Emisar.Accounts.{MembershipRunnerScope, RunnerAccess}
  alias Emisar.{ApiKeys, Audit, Auth, Billing, Crypto, Mail, Repo, Slug, SSO, Users}
  alias Emisar.Auth.Subject

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
  Internal — lock the account row (`FOR NO KEY UPDATE`) inside the CALLER's
  transaction (pass the Multi's `repo`) so concurrent per-account work serializes
  on it. The default requires an active account; `include_deleted?: true` is for
  provider lifecycle receipts that must serialize with account closure after the
  row is tombstoned.

  Runners uses it as the first step of its registration / enable Multi:
  the plan-limit count is a TOCTOU otherwise (two callers both read `current <
  limit` and both insert, exceeding the ceiling).
  """
  def fetch_and_lock_account(account_id, opts \\ []) do
    if Repo.valid_uuid?(account_id) do
      repo = Keyword.get(opts, :repo, Repo)

      queryable =
        if Keyword.get(opts, :include_deleted?, false),
          do: Account.Query.all(),
          else: Account.Query.active()

      queryable
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

      Membership.Query.authorized()
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
  The account's `require_sso` / `require_mfa` decision for one caller — the ONE
  policy the LiveView hooks, the controller plug, and the OAuth consent mint all
  run, so the enforcement paths can't drift. `account` is the account being
  entered (the OAuth grant's CHOSEN account, not necessarily the session's), and
  it must be the subject's own. Returns:

    * `{:error, :sso_required}` — the account mandates SSO and this session did
      not authenticate via THAT account's own SSO (a magic-link session, or an
      SSO session for a different account); the caller sends the operator to the
      account's step-up.
    * `{:error, :mfa_required}` — the account mandates MFA and this session has
      neither proved the user's current local enrollment nor authenticated
      through an MFA-satisfying IdP of this account; the caller funnels it into
      enrollment or a current-factor challenge.
    * `{:error, :unauthorized}` — the subject cannot view its account.
    * `{:error, :not_found}` — `account` is not the subject's account.
    * `:ok` — compliant, or the account mandates neither control.

  SSO precedence mirrors the hook order (SSO is satisfied before MFA is asked
  for). LOCATION exemptions (the sso_required shim, the MFA interstitial, the
  profile page) are the caller's to layer on — they turn on WHERE the request
  lands, not on whether the account is compliant.
  """
  def ensure_account_compliant(%Account{} = account, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_own_account_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, account.id) do
      cond do
        sso_step_up_required?(account, subject) -> {:error, :sso_required}
        mfa_enrollment_required?(account, subject) -> {:error, :mfa_required}
        true -> :ok
      end
    end
  end

  # require_sso: an enabled-SSO account this session did NOT authenticate via.
  # Defensive fail-OPEN when require_sso is on but no usable provider remains (an
  # out-of-band removal) — recoverable, not a brick, and the provider write paths
  # guard the UI path in.
  defp sso_step_up_required?(%Account{} = account, %Subject{} = subject) do
    cond do
      not account.settings.require_sso -> false
      sso_session_for_account?(subject, account) -> false
      SSO.list_enabled_providers_for_account(account.id) == [] -> false
      true -> true
    end
  end

  defp sso_session_for_account?(%Subject{} = subject, %Account{} = account) do
    subject.auth_method == :sso and
      SSO.identity_belongs_to_account?(subject.user_identity_id, account.id)
  end

  # require_mfa: an enforcing account needs proof bound to THIS session and the
  # user's CURRENT local enrollment. Enrollment alone is not proof: otherwise a
  # stolen pre-enrollment cookie becomes compliant when its victim enrolls. An
  # SSO session is independently exempt only while THIS account's provider says
  # it enforces MFA.
  defp mfa_enrollment_required?(%Account{} = account, %Subject{} = subject) do
    cond do
      not account.settings.require_mfa -> false
      local_mfa_session_current?(subject) -> false
      sso_session_satisfies_mfa?(subject, account) -> false
      true -> true
    end
  end

  # Both values must be timestamps before equality: nil == nil would otherwise
  # turn an unenrolled actor and an unproved session into a valid pair. OAuth
  # copies the proved epoch while replacing `actor` with its locked re-read, so
  # disable/re-enroll between consent render and mint fails this same choke point.
  defp local_mfa_session_current?(%Subject{
         actor: %Users.User{mfa_enabled_at: %DateTime{} = enabled_at},
         mfa_enrollment_verified_at: %DateTime{} = verified_enrollment
       })
       when enabled_at == verified_enrollment,
       do: true

  defp local_mfa_session_current?(%Subject{}), do: false

  # Account-scoped: the SSO identity must belong to THIS account AND its provider
  # must satisfy MFA. A session SSO-authed via a DIFFERENT account's IdP inherits
  # no MFA exemption here — it never proved a second factor to THIS account.
  defp sso_session_satisfies_mfa?(%Subject{} = subject, %Account{} = account) do
    sso_session_for_account?(subject, account) and
      SSO.identity_satisfies_mfa?(subject.user_identity_id)
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

  The subject must be SCOPED TO THE TARGET account — the admin console builds a
  support subject for the account being disabled — and hold
  `manage_own_account`. The account-scope check is load-bearing, not decoration:
  `manage_own_account` is held by every owner/admin for their OWN account, so
  without it a future tenant-facing caller passing a foreign `account_id` would
  fail open and disable any account by id.
  """
  def set_account_disabled_for_support(
        account_id,
        disabled?,
        reason,
        %Subject{} = subject
      )
      when is_boolean(disabled?) and is_binary(reason) and byte_size(reason) in 1..500 do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_own_account_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, account_id) do
      Account.Query.not_deleted()
      |> Account.Query.by_id(account_id)
      |> Repo.fetch_and_update(Account.Query,
        with: &account_lifecycle_changeset(&1, disabled?),
        audit: &account_lifecycle_audit(&1, &2, subject, reason),
        after_commit: &after_account_lifecycle_change/2
      )
    end
  end

  def set_account_disabled_for_support(_account_id, _disabled?, _reason, %Subject{}),
    do: {:error, :invalid_reason}

  @doc """
  Internal support write: close an account for good.

  Cancels the Paddle subscription FIRST, then tombstones the account, both in
  one transaction — so a Paddle failure leaves the account open rather than
  producing a closed account that keeps being billed. `SyncSubscriptions` also
  skips a deleted account's subscription, which is what stops the hourly
  reconcile pulling the cancelled plan straight back.

  Soft delete, not a hard one: every default scope is `not_deleted`, so the
  account disappears while its run history and audit rows stay intact.

  No console surface — this is reachable from a remote shell. It takes a
  `%Subject{}` and gates on the same permission as the other support writes so
  exposing it later is wiring, not a rewrite.

  `{:ok, account} | {:error, :invalid_reason | :not_found | term()}`.
  """
  def close_account(account_id, reason, %Subject{} = subject)
      when is_binary(reason) and byte_size(reason) in 1..500 do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_own_account_permission()
           ) do
      Multi.new()
      |> Multi.run(:account, fn repo, _changes ->
        Account.Query.not_deleted()
        |> Account.Query.by_id(account_id)
        |> Account.Query.lock_for_update()
        |> repo.fetch(Account.Query)
      end)
      |> Multi.run(:subscription, fn _repo, %{account: account} ->
        cancel_account_subscription(account)
      end)
      |> Multi.update(:closed, fn %{account: account} ->
        Account.Changeset.delete(account)
      end)
      |> Multi.insert(:audit, fn %{closed: account} ->
        Audit.Events.account_closed_by_support(subject, account, reason)
      end)
      |> Repo.commit_multi()
      |> case do
        {:ok, %{closed: account}} ->
          :ok = broadcast_account_disabled(account.id)
          disconnect_account_members(account.id)
          {:ok, account}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def close_account(_account_id, _reason, %Subject{}), do: {:error, :invalid_reason}

  # Cancelling before the tombstone means a Paddle outage aborts the close
  # rather than leaving an account that is gone from the product and still
  # paying for it. A complimentary or never-subscribed account has nothing to
  # cancel and closes cleanly.
  defp cancel_account_subscription(%Account{} = account) do
    case Billing.cancel_subscription_for_close(account) do
      :ok -> {:ok, :cancelled}
      {:error, reason} -> {:error, {:paddle_cancel_failed, reason}}
    end
  end

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

  # Disconnect the members' live sockets so every mounted LiveView remounts and
  # re-resolves; do NOT delete their session tokens.
  #
  # A session token is per-USER, not per-account — the account is resolved from
  # the URL on every request — so revoking them signed a member out of every
  # OTHER account they belong to as well, mid-incident, with no audit event
  # naming those accounts. Nothing is lost by not revoking: authorization for
  # the disabled account is enforced at request time
  # (`Auth.fetch_user_and_token_by_session_token/1` matches
  # `%Account{disabled_at: nil}`), so a remount cannot get back in.
  defp disconnect_account_members(account_id) do
    Membership.Query.not_deleted()
    |> Membership.Query.by_account_id(account_id)
    |> Membership.Query.with_preloaded_user()
    |> Repo.all()
    |> Enum.each(&Auth.broadcast_disconnect_for_user(&1.user))

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
  Accounts the subject's user is currently authorized to enter, name-ordered.
  Suspended, removed, and unresolved invited seats are excluded. Returns
  `{:ok, [account], %Paginator.Metadata{}}`. Drives the account picker.

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
  Internal — pre-auth self-serve signup. Validates the proposed workspace first,
  then creates only the unconfirmed user. The workspace cannot exist publicly
  until that address proves its magic link; `put_owner_registration/2` composes
  it into the final session transaction. Existing and new emails can therefore
  return the same public response without a slug or account-row side channel.

  A rejected form value comes back tagged with the step that owns it —
  `{:error, {:user | :account, changeset}}`; an existing address is the neutral
  `{:error, :email_taken}` branch the web maps to the same magic-link POST.
  """
  def begin_owner_registration(user_attrs, account_attrs) do
    case Ecto.Changeset.apply_action(Account.Changeset.create(account_attrs), :insert) do
      {:ok, _account} ->
        case Ecto.Changeset.apply_action(Users.change_user(%Users.User{}, user_attrs), :insert) do
          {:ok, candidate} ->
            # The inbox has not been proved yet, so persist only the address
            # needed to deliver that proof. The submitted profile lands in the
            # exact-factor completion transaction, never on a reusable user row
            # an unauthenticated caller could pre-name for invitations.
            case Users.register_user(%{email: candidate.email}) do
              {:ok, _user} ->
                resume_owner_registration(user_attrs)

              {:error, %Ecto.Changeset{} = changeset} ->
                if Repo.Changeset.unique_constraint_error?(changeset) do
                  resume_owner_registration(user_attrs)
                else
                  {:error, {:user, changeset}}
                end
            end

          {:error, changeset} ->
            {:error, {:user, changeset}}
        end

      {:error, changeset} ->
        {:error, {:account, changeset}}
    end
  end

  @doc """
  Internal compositional half of self-serve signup. The caller has already
  locked and proved the `:user` in its Multi. A registration intent map creates
  the account, owner membership, default policy, and signup audits in that same
  transaction; `nil` records an ordinary sign-in. The `:registration` result is
  the only source of the boundary's welcome/analytics decision.
  """
  def put_owner_registration(
        %Multi{} = multi,
        %{account_name: account_name, full_name: full_name}
      )
      when is_binary(account_name) and (is_binary(full_name) or is_nil(full_name)) do
    account_attrs = %{name: account_name, slug: suggest_unique_slug(account_name)}

    multi
    |> put_account_with_owner(account_attrs, :registration_user)
    |> Multi.put(:registration, true)
  end

  def put_owner_registration(%Multi{} = multi, nil),
    do: Multi.put(multi, :registration, false)

  @doc """
  Internal compositional guard for a deferred owner registration. The caller
  must already hold the `:user` row `FOR UPDATE`. A replay after the first
  sign-in therefore becomes an ordinary magic-link request instead of creating
  another account. Membership eligibility is decided once when signup creates
  the encrypted handoff; an unrelated invitation arriving during inbox proof
  must not cancel the workspace the operator asked to create.
  """
  def put_owner_registration_intent(
        %Multi{} = multi,
        %{account_name: account_name, full_name: full_name} = intent
      )
      when is_binary(account_name) and (is_binary(full_name) or is_nil(full_name)) do
    put_owner_registration_intent(multi, fn _changes -> intent end)
  end

  def put_owner_registration_intent(%Multi{} = multi, account_name_fn)
      when is_function(account_name_fn, 1) do
    Multi.run(multi, :owner_registration, fn _repo, %{user: user} = changes ->
      intent = account_name_fn.(changes)

      if valid_owner_registration_intent?(intent) and is_nil(user.last_sign_in_at),
        do: {:ok, intent},
        else: {:ok, nil}
    end)
  end

  def put_owner_registration_intent(%Multi{} = multi, nil),
    do: Multi.put(multi, :owner_registration, nil)

  defp valid_owner_registration_intent?(%{account_name: account_name, full_name: full_name}),
    do: is_binary(account_name) and (is_binary(full_name) or is_nil(full_name))

  defp valid_owner_registration_intent?(_intent), do: false

  # A browser can disappear after the unconfirmed user insert but before the
  # magic request, or after inbox verification but before the final workspace
  # transaction. Let that zero-membership, never-signed-in row resume without
  # exposing the distinction publicly. Membership or a prior sign-in is the
  # durable evidence that this is an established operator instead.
  defp resume_owner_registration(user_attrs) do
    email = user_attrs[:email] || user_attrs["email"]

    result =
      Repo.transaction(fn ->
        with true <- is_binary(email),
             {:ok, %Users.User{} = observed_user} <- Users.fetch_user_by_email(email),
             {:ok, %Users.User{} = locked_user} <-
               Users.fetch_and_lock_user_by_id(observed_user.id, Repo),
             true <- locked_user.email == observed_user.email do
          memberships =
            Membership.Query.not_deleted()
            |> Membership.Query.by_user_id(locked_user.id)

          has_memberships? = Repo.exists?(memberships)

          if is_nil(locked_user.last_sign_in_at) and not has_memberships?,
            do: {:ok, locked_user},
            else: {:error, :email_taken}
        else
          _ -> {:error, :email_taken}
        end
      end)

    case result do
      {:ok, outcome} -> outcome
      {:error, _reason} -> {:error, :email_taken}
    end
  end

  @doc """
  Internal — onboarding: an existing user stands up another workspace, so unlike
  `begin_owner_registration/2` there is a user row already but still no `%Subject{}` for
  the new tenant. Creates an account with the given user as `:owner`, wrapped
  in a transaction so a half-created account is impossible. Audit-logs both
  `user.signed_up` (the new user) and `account.created` (the new tenant) —
  together they form the "this person stood up a new team" trace operators need
  for billing/abuse review.
  """
  def create_account_with_owner(account_attrs, %Users.User{} = user) do
    Multi.new()
    |> Multi.run(:user, fn _repo, _changes -> {:ok, user} end)
    |> put_account_with_owner(account_attrs)
    |> Repo.commit_multi(after_commit: &after_membership_activation_committed/1)
    |> case do
      {:ok, %{account: account}} -> {:ok, account}
      {:error, {_step, %Ecto.Changeset{} = changeset}} -> {:error, changeset}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Internal — onboarding from the workspace form, which has one input: derive
  the unique slug from the operator-typed `name` and create the account with
  `user` as `:owner`. No `%Subject{}` can exist for this new tenant yet. A
  rejected slug is reported on `:name` — the only field the operator can
  correct it through. Returns
  `{:ok, account} | {:error, %Ecto.Changeset{} | reason}`.
  """
  def create_account_with_owner_from_name(name, %Users.User{} = user) do
    case create_account_with_owner(%{name: name, slug: suggest_unique_slug(name)}, user) do
      {:ok, account} ->
        {:ok, account}

      {:error, %Ecto.Changeset{data: %Account{}} = changeset} ->
        {:error, surface_slug_error_on_name(changeset)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A 1-2 character name passes the name validation but derives a slug the
  # account slug format rejects. The form has no slug input, so that error would
  # be orphaned — copy it onto the field the operator controls.
  defp surface_slug_error_on_name(%Ecto.Changeset{} = changeset) do
    case {changeset.errors[:name], changeset.errors[:slug]} do
      {nil, {message, opts}} -> Ecto.Changeset.add_error(changeset, :name, message, opts)
      _ -> changeset
    end
  end

  # The workspace half of standing up a new tenant. Public signup validates the
  # workspace before observing email uniqueness; this builder runs only after
  # inbox proof and keeps the account, owner seat, policy, and audits atomic.
  defp put_account_with_owner(%Multi{} = multi, account_attrs, user_key \\ :user) do
    multi
    |> put_registration_account(account_attrs)
    |> put_owner_membership(user_key)
  end

  defp put_registration_account(%Multi{} = multi, account_attrs) do
    Multi.run(multi, :account, fn repo, _changes ->
      changeset = Account.Changeset.create(account_attrs)
      tag_signup_error(:account, repo.insert(changeset))
    end)
  end

  defp put_owner_membership(%Multi{} = multi, user_key) do
    multi
    |> Multi.run(:membership, fn repo, %{account: account} = changes ->
      user = Map.fetch!(changes, user_key)

      changeset =
        Membership.Changeset.create(%{
          account_id: account.id,
          user_id: user.id,
          role: :owner,
          runner_access_mode: :all
        })

      tag_signup_error(:membership, repo.insert(changeset))
    end)
    # Making your own workspace is a second membership like any other: it ends the
    # single-account assumption an admin-approved binding elsewhere was granted on.
    |> Multi.merge(fn %{membership: membership} ->
      put_membership_activation_consequence(Multi.new(), membership)
    end)
    # Workspace gets the v2 conservative default policy on creation.
    # Without this, `Policies.evaluate(nil, ...)` would default-deny
    # every dispatch — which is correct but unhelpful as a first run.
    |> Multi.run(:policy, fn _repo, %{account: account} = changes ->
      user = Map.fetch!(changes, user_key)
      Emisar.Policies.seed_policy(account.id, user.id)
    end)
    |> Multi.insert(:account_created, fn %{account: account} = changes ->
      user = Map.fetch!(changes, user_key)
      Audit.Events.account_created(account, user)
    end)
    |> Multi.insert(:user_signed_up, fn %{account: account} = changes ->
      user = Map.fetch!(changes, user_key)
      Audit.Events.user_signed_up(user, account)
    end)
  end

  defp tag_signup_error(_step, {:ok, row}), do: {:ok, row}

  defp tag_signup_error(step, {:error, %Ecto.Changeset{} = changeset}),
    do: {:error, {step, changeset}}

  @doc """
  Update an account's settings. The required permission is **field-aware**:
  changing a security setting needs `manage_security_settings` (owner +
  admin), while a rename/rebrand or a plain preference (the monthly-report
  opt-out) only needs `manage_own_account`.

  When `require_mfa` is flipped on, every signed-in user without
  `mfa_enabled_at` is funneled to MFA setup by
  `EmisarWeb.UserAuth.on_mount(:ensure_mfa_compliant)` until they enroll
  (owners included) — so turning it on requires the caller to be enrolled
  themselves (`{:error, :mfa_enrollment_required}`). Turning it off is always
  allowed. A security change is audited as `account.require_mfa_set`,
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

          with :ok <- ensure_security_change_permitted(changeset, subject),
               :ok <- ensure_mfa_requirement_has_an_enrolled_actor(changeset, subject),
               :ok <- ensure_sso_requirement_has_a_way_in(loaded_account, changeset) do
            changeset
          else
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

  @doc """
  Internal — Catalog owns the pack-cleanup contract (permission, tenancy, and
  the period's validation); this writes the canonical result to
  `settings.pack_unseen_retention_days` on the active account, audited as
  `account.updated` in the same transaction. `nil` turns cleanup off. Returns
  `{:ok, account}` or `{:error, %Ecto.Changeset{} | :not_found}`.
  """
  def put_account_pack_retention_days(account_id, days, %Subject{} = subject)
      when is_nil(days) or (is_integer(days) and days > 0) do
    if Repo.valid_uuid?(account_id) do
      Account.Query.active()
      |> Account.Query.by_id(account_id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Account.Query,
        with: &Account.Changeset.update(&1, %{settings: %{pack_unseen_retention_days: days}}),
        audit: &account_update_audit(&1, &2, subject)
      )
    else
      {:error, :not_found}
    end
  end

  @doc """
  Internal — Runners owns the runner-cleanup contract (permission, the
  unrestricted-runner-access requirement, tenancy, and the window's
  validation); this writes the canonical result to
  `settings.runner_inactive_retention_hours` on the active account, audited as
  `account.updated` in the same transaction. `nil` turns cleanup off. Returns
  `{:ok, account}` or `{:error, %Ecto.Changeset{} | :not_found}`.
  """
  def put_account_runner_inactive_retention_hours(account_id, hours, %Subject{} = subject)
      when is_nil(hours) or (is_integer(hours) and hours > 0) do
    if Repo.valid_uuid?(account_id) do
      Account.Query.active()
      |> Account.Query.by_id(account_id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Account.Query,
        with: &Account.Changeset.put_runner_inactive_retention_hours(&1, hours),
        audit: &account_update_audit(&1, &2, subject)
      )
    else
      {:error, :not_found}
    end
  end

  @doc """
  Internal — Approvals owns the standing-grant cap contract (permission,
  tenancy, the value's validation, and the revocation sweep a zero cap
  triggers); this writes the canonical result to
  `settings.max_grant_lifetime_seconds` on the active account, audited as
  `account.max_grant_lifetime_set` in the same transaction. `nil` removes the
  cap; `0` disables standing grants. Returns `{:ok, account}` or
  `{:error, %Ecto.Changeset{} | :not_found}`.
  """
  def put_account_max_grant_lifetime_seconds(account_id, seconds, %Subject{} = subject)
      when is_nil(seconds) or (is_integer(seconds) and seconds >= 0) do
    if Repo.valid_uuid?(account_id) do
      Account.Query.active()
      |> Account.Query.by_id(account_id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Account.Query,
        with: &Account.Changeset.put_max_grant_lifetime_seconds(&1, seconds),
        audit: &account_update_audit(&1, &2, subject)
      )
    else
      {:error, :not_found}
    end
  end

  # Enforcing MFA funnels the actor too, so an unenrolled caller flipping it on
  # locks themselves out. It is a domain invariant, not a Team-page courtesy: the
  # check runs inside the locked write on the actor's CURRENT row, so a stale
  # socket snapshot (or a forged event) cannot carry an unenrolled owner past it.
  defp ensure_mfa_requirement_has_an_enrolled_actor(
         %Ecto.Changeset{} = changeset,
         %Subject{} = subject
       ) do
    if Map.get(settings_changes(changeset), :require_mfa) == true do
      ensure_actor_enrolled_through_commit(subject)
    else
      :ok
    end
  end

  # The account row is already held here, so account → user is this path's lock
  # order. Taking the user row (rather than reading it) is what makes the answer
  # survive to COMMIT: `Auth.disable_mfa/2` clears `mfa_enabled_at` on that same
  # row, and a fresh-but-unlocked SELECT can still observe an enrollment the
  # concurrent disable is about to commit — leaving enforcement on with the
  # actor unable to satisfy it. A tombstoned or missing actor row, and a subject
  # with no user behind it, answer the same as an unenrolled one rather than
  # leaking `:not_found`.
  defp ensure_actor_enrolled_through_commit(%Subject{actor: %Users.User{id: user_id}}) do
    case Users.fetch_and_lock_user_by_id(user_id, Repo) do
      {:ok, %Users.User{mfa_enabled_at: %DateTime{}}} -> :ok
      _ -> {:error, :mfa_enrollment_required}
    end
  end

  defp ensure_actor_enrolled_through_commit(%Subject{}), do: {:error, :mfa_enrollment_required}

  # Requiring SSO with no enabled connection locks EVERYONE out, owners included.
  # That check lived only in the Team page's click handler, so any other caller
  # could set it, and even through the UI it was a read taken outside the write's
  # transaction: enabling could observe a provider a concurrent disable was
  # removing, and two concurrent disables could each observe the other still
  # enabled. Every one of those lands on require_sso with zero providers, which
  # enforcement treats as fail-open — magic-link sessions are accepted.
  #
  # Judged here, on the FRESH changeset under the account row lock, so the
  # invariant holds for every caller and the provider read is serialized against
  # the other half by the same lock the disable path takes.
  defp ensure_sso_requirement_has_a_way_in(%Account{} = account, %Ecto.Changeset{} = changeset) do
    if Map.get(settings_changes(changeset), :require_sso) == true and
         SSO.list_enabled_providers_for_account(account.id) == [] do
      {:error, :require_sso_without_provider}
    else
      :ok
    end
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
  # "is this a security change?" is FIELD-aware: only require_mfa and require_sso
  # need manage_security_settings. A preference like monthly_report_opt_out rides
  # the same embed but is not security — over-gating it at the most-privileged
  # level would wrongly block low-privilege edits. The standing-grant cap is a
  # security knob too, but Approvals owns it: this path refuses the field
  # outright (`Account.Settings`), so there is nothing here to gate.
  @security_settings_fields ~w[require_mfa require_sso]a

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
  Advances the authenticated user's current membership activity timestamp when
  its previous value is older than five minutes. Requires `view_own_account`;
  the membership id, user id, active account, and subject account must all
  agree. Returns `{:ok, :touched | :unchanged}` or `{:error, :unauthorized}`.
  """
  def touch_membership_activity(%Subject{membership_id: membership_id} = subject) do
    user_id = Subject.user_id(subject)

    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_own_account_permission()
           ),
         true <- Repo.valid_uuid?(membership_id) and Repo.valid_uuid?(user_id) do
      now = DateTime.utc_now()

      {count, _} =
        Membership.Query.authorized()
        |> Membership.Query.by_id(membership_id)
        |> Membership.Query.by_user_id(user_id)
        |> Membership.Query.with_joined_account()
        |> Membership.Query.last_active_before(DateTime.add(now, -5, :minute))
        |> Authorizer.for_subject(subject)
        |> Repo.update_all(set: [last_active_at: now])

      if count == 1, do: {:ok, :touched}, else: {:ok, :unchanged}
    else
      false -> {:ok, :unchanged}
      {:error, :unauthorized} = error -> error
    end
  end

  @doc """
  Filter definitions for the Team roster. The membership query owns the SQL;
  the context exposes its UI-safe vocabulary so the web never reaches into a
  query module.
  """
  def team_member_filters, do: Membership.Query.filters()

  @doc """
  One page of the team roster as presentation facts: each visible membership plus
  the security state the roster renders and the member actions it may offer. Owns
  the membership page, its user preload, and ONE batched runner-scope read, so the
  web never derives a capability from an invitation, MFA, suspension, or directory
  column itself.

  Requires `view_own_account` and that `subject` is in `account`; scoped by the
  explicit account id alongside `Authorizer.for_subject/2`. Returns
  `{:ok, [facts], %Paginator.Metadata{}}`.
  """
  def list_team_member_facts(%Account{id: account_id}, %Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_own_account_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, account_id, :unauthorized),
         {:ok, memberships, metadata} <- list_team_memberships(account_id, subject, opts) do
      access_by_membership = runner_access_for_memberships(memberships)
      manager? = subject_can_manage_team?(subject)
      suspended_by_labels = suspended_by_labels(memberships, account_id, manager?)

      facts =
        Enum.map(
          memberships,
          &team_member_facts(
            &1,
            access_by_membership,
            suspended_by_labels,
            manager?,
            subject
          )
        )

      {:ok, facts, metadata}
    end
  end

  defp list_team_memberships(account_id, %Subject{} = subject, opts) do
    Membership.Query.not_deleted()
    |> Membership.Query.by_account_id(account_id)
    |> Membership.Query.with_preloaded_user()
    |> Authorizer.for_subject(subject)
    |> Repo.list(Membership.Query, opts)
  end

  @doc """
  One team member's facts, read FRESH from the subject's account — the gate an
  inline editor opens on. The roster a page loaded minutes ago cannot answer
  whether a directory has claimed this member since, so the editor asks again
  rather than trusting the row it rendered.

  Requires `view_own_account`; scoped by `Authorizer.for_subject/2`. Returns
  `{:ok, facts}` or `{:error, :not_found | :unauthorized}`.
  """
  def fetch_team_member_facts(membership_id, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_own_account_permission()
           ),
         {:ok, membership} <- fetch_team_membership(membership_id, subject) do
      access_by_membership = runner_access_for_memberships([membership])
      manager? = subject_can_manage_team?(subject)
      suspended_by_labels = suspended_by_labels([membership], membership.account_id, manager?)

      {:ok,
       team_member_facts(
         membership,
         access_by_membership,
         suspended_by_labels,
         manager?,
         subject
       )}
    end
  end

  defp fetch_team_membership(membership_id, %Subject{} = subject) do
    if Repo.valid_uuid?(membership_id) do
      Membership.Query.not_deleted()
      |> Membership.Query.by_id(membership_id)
      |> Membership.Query.with_preloaded_user()
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Membership.Query)
    else
      {:error, :not_found}
    end
  end

  # Suspension and a still-open invitation are independent facts — a suspended
  # member who never accepted is both — so each keeps its own boolean and the
  # actions that depend on the pair say so (`resend_invitation?`).
  defp team_member_facts(
         %Membership{} = membership,
         access_by_membership,
         suspended_by_labels,
         manager?,
         %Subject{} = subject
       ) do
    pending_invitation? = membership_invitation_pending?(membership)
    disabled? = Membership.disabled?(membership)
    mfa_enrolled? = member_mfa_enrolled?(membership.user)
    confirmation_pending? = member_confirmation_pending?(membership.user)
    self_owner? = self_owner?(membership, subject)

    facts = %{
      # The digest is credential material behind the join link, and the raw
      # suspender id is manager-only provenance. The roster needs neither.
      membership: %{membership | invitation_token_digest: nil, disabled_by_id: nil},
      pending_invitation?: pending_invitation?,
      self_owner?: self_owner?,
      disabled?: disabled?,
      mfa_enrolled?: mfa_enrolled?,
      confirmation_pending?: confirmation_pending?,
      runner_access: Map.get(access_by_membership, membership.id, RunnerAccess.none()),
      runner_access_editable?: not membership.runner_access_directory_managed,
      role_editable?: not self_owner? and not membership.directory_managed,
      resend_invitation?: pending_invitation? and not disabled?,
      resend_confirmation?:
        confirmation_pending? and membership.user_id == Subject.actor_id(subject),
      reset_mfa?: mfa_enrolled? and not pending_invitation?
    }

    if manager? do
      Map.put(facts, :suspended_by_label, Map.get(suspended_by_labels, membership.disabled_by_id))
    else
      facts
    end
  end

  defp suspended_by_labels(memberships, account_id, true) do
    memberships
    |> Enum.map(& &1.disabled_by_id)
    |> user_labels_for_ids(account_id)
  end

  defp suspended_by_labels(_memberships, _account_id, false), do: %{}

  @doc "Whether a membership is an unresolved account invitation."
  defdelegate membership_invitation_pending?(membership),
    to: Membership,
    as: :invitation_pending?

  @doc "Whether a loaded membership currently grants account authority."
  defdelegate membership_authorized?(membership), to: Membership, as: :authorizable?

  defp member_mfa_enrolled?(%Users.User{mfa_enabled_at: %DateTime{}}), do: true
  defp member_mfa_enrolled?(_user), do: false

  defp member_confirmation_pending?(%Users.User{confirmed_at: nil}), do: true
  defp member_confirmation_pending?(_user), do: false

  # Only the ACTOR's own owner row is off-limits: an owner editing another owner,
  # or an admin editing their own row, is ordinary team administration.
  defp self_owner?(%Membership{user_id: user_id, role: :owner}, %Subject{
         actor: %Users.User{id: user_id}
       }),
       do: true

  defp self_owner?(%Membership{}, %Subject{}), do: false

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

  defp sole_owner?(repo, %Membership{account_id: account_id, role: :owner} = membership) do
    if Membership.authorizable?(membership) do
      owner_memberships =
        Membership.Query.authorized()
        |> Membership.Query.by_account_id(account_id)
        |> Membership.Query.by_role(:owner)

      repo.aggregate(owner_memberships, :count, :id) == 1
    else
      false
    end
  end

  defp sole_owner?(_repo, %Membership{}), do: false

  @doc """
  The account's security posture for the team rail, read from CURRENT state: MFA
  enrollment across every member, how many of them can manage the team, whether
  enforcement is on (and whether the caller could turn it on without locking
  themselves out), and whether SSO is required.

  The denominator is every non-deleted membership — suspended and still-pending
  included — so the count matches the roster rather than one page of it, and the
  account row, its settings, and the actor's own enrollment are all re-read here
  rather than taken from a long-lived socket snapshot. `team_managers` shares
  that denominator, so it can never exceed the member count beside it. Requires
  `view_own_account`. Returns `{:ok, facts}` or `{:error, :not_found |
  :unauthorized}`.
  """
  def fetch_team_security_facts(%Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_own_account_permission()
           ),
         {:ok, account} <- fetch_current_account(subject) do
      base = Membership.Query.not_deleted() |> Membership.Query.by_account_id(account.id)
      manager_roles = Auth.Permissions.roles_with_permission(Authorizer.manage_team_permission())

      total = base |> Authorizer.for_subject(subject) |> Repo.aggregate(:count)

      enrolled =
        base
        |> Membership.Query.with_mfa_enrolled()
        |> Authorizer.for_subject(subject)
        |> Repo.aggregate(:count)

      managers =
        base
        |> Membership.Query.by_roles(manager_roles)
        |> Authorizer.for_subject(subject)
        |> Repo.aggregate(:count)

      {:ok,
       %{
         mfa_total: total,
         mfa_enrolled: enrolled,
         mfa_missing: total - enrolled,
         team_managers: managers,
         mfa_enforcement: mfa_enforcement(account, subject),
         sso_required?: account.settings.require_sso
       }}
    end
  end

  defp fetch_current_account(%Subject{} = subject) do
    Account.Query.not_deleted()
    |> Authorizer.for_subject(subject)
    |> Repo.fetch(Account.Query)
  end

  # `:actor_not_enrolled` is why enforcement cannot be turned ON yet: the
  # enforcement gate funnels the person who flipped it too, so an owner without a
  # second factor would lock themselves out of the account they just secured.
  defp mfa_enforcement(%Account{settings: %{require_mfa: true}}, %Subject{}), do: :enforced

  defp mfa_enforcement(%Account{}, %Subject{} = subject) do
    if actor_mfa_enrolled?(subject), do: :available, else: :actor_not_enrolled
  end

  # The subject's actor is a socket snapshot that can be hours old, so the
  # enrollment question is answered from the user's current row.
  defp actor_mfa_enrolled?(%Subject{actor: %Users.User{id: user_id}}) do
    case Users.fetch_user_by_id(user_id) do
      {:ok, %Users.User{mfa_enabled_at: %DateTime{}}} -> true
      _ -> false
    end
  end

  defp actor_mfa_enrolled?(%Subject{}), do: false

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
  Internal — SSO directory rename: record the directory's name for this member,
  and say whether this account is the person's only tenancy.

  `users.full_name` is identity and deliberately cross-account, so one workspace's
  directory must not rewrite how the person reads in another's. When they belong
  here and nowhere else the directory genuinely is the authority for who they
  are, and the caller may write the global name too — which keeps the ordinary
  single-workspace case showing one name on every surface.

  The caller supplies `:audit`: this name is what the account's roster, run
  attribution and audit actor/target labels render for the member, so a
  directory moving it is always recorded.
  """
  def sync_member_display_name(account_id, user_id, display_name, opts)
      when is_binary(account_id) and is_binary(user_id) do
    audit = Keyword.fetch!(opts, :audit)

    # One transaction for the membership write AND the tenancy question. Read
    # separately, the answer could go stale between them: another account adding
    # a membership in that window let this directory's name through to a
    # workspace it has no authority over.
    Multi.new()
    |> Multi.run(:membership, fn repo, _changes ->
      queryable =
        Membership.Query.not_deleted()
        |> Membership.Query.by_account_and_user(account_id, user_id)
        |> Membership.Query.lock_for_update()

      case repo.peek(queryable) do
        nil -> {:error, :not_found}
        %Membership{} = membership -> {:ok, membership}
      end
    end)
    |> Multi.run(:updated, fn repo, %{membership: membership} ->
      write_display_name(repo, membership, display_name, audit)
    end)
    |> Multi.run(:sole_tenancy, fn repo, _changes ->
      {:ok, sole_tenancy?(repo, user_id, account_id)}
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{updated: updated, sole_tenancy: sole_tenancy?}} -> {:ok, updated, sole_tenancy?}
      {:error, reason} -> {:error, reason}
    end
  end

  # The audit row carries the pre-update membership, so the event reads
  # from→to. An unchanged name writes nothing and is not an event.
  defp write_display_name(repo, %Membership{} = membership, display_name, audit) do
    case Membership.Changeset.sync_display_name(membership, display_name) do
      {:noop, membership} ->
        {:ok, membership}

      changeset ->
        with {:ok, updated} <- repo.update(changeset),
             {:ok, _event} <- repo.insert(audit.(membership)) do
          {:ok, updated}
        end
    end
  end

  defp sole_tenancy?(repo, user_id, account_id) do
    queryable =
      Membership.Query.not_deleted()
      |> Membership.Query.by_user_id(user_id)
      |> Membership.Query.excluding_account_id(account_id)

    not repo.exists?(queryable)
  end

  @doc """
  The name this account knows a member by: the directory-synced membership
  display name when this account's IdP set one, else the user's own nonblank
  full name, else their email. Without a current `%Membership{}`, only the
  email remains safe: a former member's cross-account `users.full_name` is not
  this tenant's naming fact. Pure — attribution surfaces render its result
  verbatim instead of re-deriving naming rules.
  """
  def member_display_name(%Membership{directory_display_name: name}, _user)
      when is_binary(name) and name != "",
      do: name

  def member_display_name(%Membership{}, %Users.User{} = user), do: user_display_name(user)
  def member_display_name(_membership, %Users.User{email: email}), do: email

  @doc """
  A person's own name: their nonblank full name, else their email. Cross-account
  identity, so an account-scoped surface reaches for `member_display_name/2`
  first. Pure; `nil` for a shape carrying neither field.
  """
  def user_display_name(%{full_name: name, email: email}) when is_binary(name) do
    if String.trim(name) == "", do: email, else: name
  end

  def user_display_name(%{email: email}), do: email
  def user_display_name(_user), do: nil

  @doc """
  A person's email when it is distinct from their display name, else `nil` —
  the secondary identity line that must not repeat the primary one. Pure.
  """
  def secondary_user_email(%{email: email} = user) when is_binary(email) do
    if user_display_name(user) == email, do: nil, else: email
  end

  def secondary_user_email(_user), do: nil

  @doc """
  Internal — label resolver for approval attribution: batch
  `%{user_id => label}` for the supplied ids, each named the way THIS account
  knows the person (directory name → nonblank full name → email). Takes ids and
  an explicit already-authorized `account_id` rather than a `%Subject{}`; an id
  belonging to no current member of the account resolves to no label, so a
  mis-stamped or cross-account id can never surface a name.
  """
  def user_labels_for_ids(ids, account_id) when is_list(ids) and is_binary(account_id) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    case ids do
      [] ->
        %{}

      ids ->
        Membership.Query.not_deleted()
        |> Membership.Query.by_account_id(account_id)
        |> Membership.Query.select_user_labels(ids)
        |> Repo.all()
        |> Map.new()
    end
  end

  @doc """
  Internal — Audit's user-event fan-out: EVERY membership that currently grants
  authority, so a user-scoped security event lands one row per
  account the user belongs to (each account legitimately sees its own copy). No
  `%Subject{}` — the caller is the subject-less audit builder.
  """
  def list_active_memberships_for_user(%Users.User{id: user_id}) do
    Membership.Query.authorized()
    |> Membership.Query.by_user_id(user_id)
    |> Repo.all()
  end

  @doc """
  Internal — compose the consequence of one membership becoming active.

  Admin approval may bind an OIDC credential to an existing person only while
  they have no active membership in another account. After a direct create,
  invitation acceptance, or real reinstate, the same predicate is re-evaluated
  against the activated account; a pending or suspended seat is not access and
  does not retire anything until it becomes active. The DB-only retirement
  result carries exact socket topics to the outer commit.
  """
  def put_membership_activation_consequence(%Multi{} = multi, %Membership{} = membership) do
    Multi.run(multi, :retired_bindings, fn repo, _changes ->
      active_account_ids =
        Membership.Query.authorized()
        |> Membership.Query.by_user_id(membership.user_id)
        |> Membership.Query.select_account_ids()
        |> repo.all()
        |> Enum.uniq()

      SSO.retire_admin_approved_identities(membership.user_id, active_account_ids, repo)
    end)
  end

  @doc """
  Internal — finish the external half of a committed membership activation.
  Identity-bound session rows were deleted in the transaction; their exact
  socket topics ride in `:retired_bindings` because no query can derive them
  after the delete.
  """
  def after_membership_activation_committed(%{retired_bindings: %{socket_topics: topics}}) do
    Auth.disconnect_live_socket_topics(topics)
  end

  def after_membership_activation_committed(%{}), do: :ok

  @doc """
  Internal — the same rows as `list_active_memberships_for_user/1`, locked, for a
  caller whose decision depends on them still being true at COMMIT. Takes the
  transaction's repo so it joins the open transaction. No `%Subject{}`: the caller
  has already authorized, and the lock is the point.

  An authority check that reads these rows outside its transaction is only as good
  as the gap: a role raised in that window commits anyway.
  """
  def fetch_and_lock_active_memberships_for_user(%Users.User{} = user, repo) do
    # The USER row first, with `FOR UPDATE`. A row lock protects rows that exist,
    # so locking the memberships we can see says nothing about one another account
    # inserts while we decide — there is no predicate lock under Read Committed.
    # Holding the user row conflicts with the FK check a membership insert takes,
    # which is what makes those inserts wait. (`FOR NO KEY UPDATE` does NOT: it is
    # explicitly compatible with that check, so it let them straight through.)
    #
    # It closes the in-transaction window, not the problem. Nothing here can stop
    # an account granting a membership AFTER this commits — that boundary belongs
    # elsewhere (see the queued decision on SSO sessions reaching a second
    # account).
    {:ok, _locked_user} = Users.fetch_and_lock_user_by_id(user.id, repo)

    # Every LIVE membership, disabled ones included: a disabled membership in
    # another account can be reinstated concurrently, and excluding it before
    # locking left exactly that row unheld.
    queryable =
      Membership.Query.not_deleted()
      |> Membership.Query.by_user_id(user.id)
      |> Membership.Query.lock_for_update()

    {:ok, Enum.filter(repo.all(queryable), &membership_authorized?/1)}
  end

  @doc """
  Internal — compose SSO/SCIM membership creation into a caller's transaction.
  Active creation includes the cross-account binding consequence; a directory
  row born suspended has granted no access and deliberately skips it. The
  caller owns the outer commit and `after_membership_activation_committed/1`.
  """
  # Defense in depth: `:owner` is never assignable via sync (the provider
  # changeset rejects it as a default_role too) — owner is a deliberate human
  # grant needing `manage_owners`.
  def put_sso_membership(
        multi,
        account_id,
        user_id,
        role,
        granted,
        opts \\ []
      )

  def put_sso_membership(
        %Multi{} = multi,
        _account_id,
        _user_id,
        :owner,
        %RunnerAccess{},
        _opts
      ),
      do: Multi.error(multi, :membership, :owner_not_assignable)

  def put_sso_membership(
        %Multi{} = multi,
        account_id,
        user_id,
        role,
        %RunnerAccess{} = granted,
        opts
      ) do
    active? = Keyword.get(opts, :active?, true)
    directory_managed? = Keyword.get(opts, :directory_managed?, false)
    directory_provider = Keyword.get(opts, :directory_provider)
    # The role and the grant arrive from two independent sources — a provider's
    # `default_role` and its `default_runner_*`, or a group→role mapping beside a
    # group→runner one — so the role decides what the grant may actually be.
    access = RunnerAccess.for_role(role, granted)

    attrs = %{
      account_id: account_id,
      user_id: user_id,
      role: role,
      directory_managed: directory_managed?,
      runner_access_mode: access.mode,
      pack_access_mode: access.pack_mode,
      pack_scope_pack_ids: access.pack_ids,
      runner_access_directory_managed: directory_managed?,
      directory_provider_id: directory_provider_id(directory_provider, directory_managed?)
    }

    multi
    |> Multi.insert(:membership, sso_membership_changeset(attrs, active?))
    |> Multi.run(:runner_access, fn repo, %{membership: membership} ->
      replace_runner_access_rows(repo, membership.id, access)
    end)
    |> then(fn multi ->
      if active? do
        Multi.merge(multi, fn %{membership: membership} ->
          put_membership_activation_consequence(Multi.new(), membership)
        end)
      else
        Multi.run(multi, :retired_bindings, fn _repo, _changes ->
          {:ok, %{count: 0, socket_topics: []}}
        end)
      end
    end)
  end

  defp sso_membership_changeset(attrs, true), do: Membership.Changeset.create(attrs)
  defp sso_membership_changeset(attrs, false), do: Membership.Changeset.create_suspended(attrs)

  defp directory_provider_id(%SSO.IdentityProvider{id: id}, true), do: id
  defp directory_provider_id(_provider, _managed?), do: nil

  @doc """
  Canonical runner access for a picker's explicit mode plus the raw
  `"group:<name>"` / `"runner:<id>"` values it submitted, narrowed by the pack
  mode and its raw `"pack:<id>"` values, allowlisted against `allowlist` (a
  runner list, or a `%{groups: _, runners: _, packs: _}` fact map). Returns
  `{:ok, access} | {:error, :invalid_runner_access | :invalid_pack_access}`, so
  a crafted selection can never widen reach.
  """
  def build_runner_access(mode, values, allowlist, pack_mode \\ :all, pack_values \\ []),
    do: RunnerAccess.from_selection(mode, values, allowlist, pack_mode, pack_values)

  @doc ~s(The `"group:<name>"` / `"runner:<id>"` selector values a persisted `{groups, runner_ids}` scope renders as.)
  def runner_access_selection_values(groups, runner_ids),
    do: RunnerAccess.selection_values(groups, runner_ids)

  @doc ~s(The `"pack:<id>"` selector values a persisted pack scope renders as.)
  def pack_access_selection_values(pack_ids), do: RunnerAccess.pack_selection_values(pack_ids)

  @doc """
  The account facts a grant form's selection is resolved against — its runners
  (and the groups they name) plus the pack ids the account carries.
  """
  def runner_access_allowlist(runners, packs \\ []),
    do: RunnerAccess.allowlist(runners, packs)

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
  attempts use this before dispatch; malformed identifiers fail closed.
  """
  def runner_access_for_membership(account_id, membership_id)
      when is_binary(account_id) and is_binary(membership_id) do
    if Repo.valid_uuid?(account_id) and Repo.valid_uuid?(membership_id) do
      membership =
        Membership.Query.authorized()
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
             :ok <- ensure_role_carries_runner_access(target, access),
             :ok <- ensure_runner_access_not_directory_managed(target) do
          {:ok, :ok}
        else
          {:error, reason} -> {:error, reason}
        end
      end)
      |> Multi.update(:membership, fn %{target: target} ->
        Membership.Changeset.update_runner_access(target, access)
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
  The staff break-glass subject is exempt — it holds no membership, so it has no
  reach of its own to delegate.
  """
  # The break-glass support subject (`Emisar.Admin.support_subject/1`) is an owner
  # by permission but holds no membership in the account, so
  # `runner_access_for_subject/1` reads its reach as `none` and this cap refused
  # every staff invite and every support-run promotion. It is not delegating its
  # own reach; it is acting as the platform, and its authority is
  # `Emisar.Admin.ensure_staff/1` plus the staff audit trail, not a tenant scope.
  # BOTH nils are the guard: `Subject.for_user/5` always carries an actor AND a
  # membership, so no ordinary member can ever take this clause. One spelling
  # here covers every caller of the cap — invitations, access edits, role
  # promotions, and SSO — rather than a carve-out repeated at each.
  def ensure_runner_access_grant_allowed(
        %Subject{actor: nil, membership_id: nil},
        %RunnerAccess{}
      ),
      do: :ok

  def ensure_runner_access_grant_allowed(%Subject{} = subject, %RunnerAccess{} = access) do
    if RunnerAccess.covers?(runner_access_for_subject(subject), access),
      do: :ok,
      else: {:error, :runner_access_exceeds_subject}
  end

  defp ensure_runner_access_not_directory_managed(%Membership{
         runner_access_directory_managed: true
       }),
       do: {:error, :runner_access_managed_by_directory}

  defp ensure_runner_access_not_directory_managed(%Membership{}), do: :ok

  # ASSIGNING a role that carries no reach resets it (`RunnerAccess.for_role/2`);
  # editing the reach of someone who already holds that role is a contradiction
  # the operator has to see, so it is refused rather than silently stored as
  # nothing. Clearing it is always allowed — that is the state the role wants.
  defp ensure_role_carries_runner_access(%Membership{} = membership, %RunnerAccess{} = access) do
    if access == RunnerAccess.for_role(membership.role, access),
      do: :ok,
      else: {:error, :role_carries_no_runner_access}
  end

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
    refresh_member_sessions_if_access_changed(previous_access, access, membership)
  end

  defp broadcast_membership_runner_access_changed(%Membership{} = membership) do
    Emisar.PubSub.broadcast(
      account_team_topic(membership.account_id),
      {:list_changed, :team, "membership.runner_access_changed", membership.user_id}
    )
  end

  @doc """
  Internal — the runbook scheduler's per-attempt authorization re-check: the
  membership `membership_id` in `account_id`, nil-or-struct, ONLY if it is still
  active (not deleted, not disabled). No `%Subject{}` — the caller is the
  user-less scheduler, which already authorized at execution creation and
  re-validates the anchor before later work. A `nil` result means the
  initiating member was suspended/deleted mid-execution → the engine halts.
  """
  def peek_active_membership(account_id, membership_id)
      when is_binary(account_id) and is_binary(membership_id) do
    Membership.Query.authorized()
    |> Membership.Query.by_account_id(account_id)
    |> Membership.Query.by_id(membership_id)
    |> Repo.peek()
  end

  def peek_active_membership(_account_id, _membership_id), do: nil

  @doc """
  Internal — API-key authentication's active membership/account check inside
  the caller's transaction. This deliberately does not take a membership lock:
  deprovisioning locks the membership before revoking its keys, while raw-secret
  authentication locks the key first. Avoiding the inverse lock order prevents
  a deadlock; after deprovision commits, both checks fail closed.
  """
  def fetch_active_membership(repo, account_id, membership_id)
      when is_binary(account_id) and is_binary(membership_id) do
    Membership.Query.authorized()
    |> Membership.Query.by_account_id(account_id)
    |> Membership.Query.by_id(membership_id)
    |> Membership.Query.with_joined_account()
    |> repo.fetch(Membership.Query)
  end

  def fetch_active_membership(_repo, _account_id, _membership_id), do: {:error, :not_found}

  @doc """
  Internal — approval notification eligibility: the active membership for one
  user in one account. Returns `{:ok, membership} | {:error, :not_found}`.
  """
  def fetch_active_membership_for_user(account_id, user_id)
      when is_binary(account_id) and is_binary(user_id) do
    Membership.Query.authorized()
    |> Membership.Query.by_account_and_user(account_id, user_id)
    |> Repo.fetch(Membership.Query)
  end

  def fetch_active_membership_for_user(_account_id, _user_id), do: {:error, :not_found}

  @doc "Internal - lock a run initiator's current active membership in the caller's transaction."
  def fetch_and_lock_active_membership(repo, account_id, membership_id)
      when is_binary(account_id) and is_binary(membership_id) do
    Membership.Query.authorized()
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
  if `account_id` is given and the user has an authorized membership on that
  (non-deleted) account, return it; otherwise fall back to the most
  recently-joined authorized membership — the default for first sign-in or after
  a stale session value is cleared. Unresolved invitations grant no access.
  Returns
  `{:ok, membership} | {:error, :not_found}`.
  """
  def fetch_membership_for_session(%Users.User{id: user_id}, account_id) do
    case maybe_fetch_session_membership(user_id, account_id) do
      {:ok, membership} ->
        {:ok, membership}

      {:error, :not_found} ->
        Membership.Query.authorized()
        |> Membership.Query.by_user_id(user_id)
        |> Membership.Query.with_preloaded_account()
        |> Membership.Query.with_preloaded_user()
        |> Membership.Query.latest()
        |> Repo.fetch(Membership.Query)
    end
  end

  defp maybe_fetch_session_membership(user_id, account_id) do
    if Repo.valid_uuid?(account_id) do
      Membership.Query.authorized()
      |> Membership.Query.by_account_and_user(account_id, user_id)
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
  403). Suspended (`disabled_at`) members, unresolved invitations, and
  soft-deleted accounts/users are excluded.
  """
  def fetch_membership_by_account_id_or_slug(%Users.User{id: user_id}, account_id_or_slug) do
    Membership.Query.authorized()
    |> Membership.Query.by_user_id(user_id)
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
  Internal — post-factor sign-in: `Auth.resolve_post_auth_account/2` resolves the
  branded `/app/:account_id_or_slug` target once both factors have passed, so no
  `%Subject{}` exists yet. Scoped to the user's OWN live membership, and — unlike
  `fetch_membership_by_account_id_or_slug/2` — the preloaded account may be
  DISABLED, so a member of a disabled account can be routed to that account's own
  page. An unknown ref, a non-member, a suspended or tombstoned membership, an
  unresolved invitation, and a deleted account all return `{:error, :not_found}`
  — indistinguishable, so sign-in never confirms a tenant exists.
  """
  def fetch_post_auth_membership(%Users.User{id: user_id}, account_id_or_slug)
      when is_binary(account_id_or_slug) do
    Membership.Query.authorized()
    |> Membership.Query.by_user_id(user_id)
    |> scope_to_account_ref_including_disabled(account_id_or_slug)
    |> Membership.Query.with_preloaded_account_including_disabled()
    |> Repo.fetch(Membership.Query)
  end

  defp scope_to_account_ref_including_disabled(queryable, account_id_or_slug) do
    if Repo.valid_uuid?(account_id_or_slug) do
      Membership.Query.by_account_id(queryable, account_id_or_slug)
    else
      Membership.Query.by_account_slug_including_disabled(queryable, account_id_or_slug)
    end
  end

  @doc """
  Switch the operator's active tenant to `account_id`. Requires
  `view_own_account_permission`. Returns `{:ok, membership}` — the freshly
  validated target membership with `:account` and `:user` preloaded, which the
  web boundary pins in the session and redirects to — or `{:error, :not_found}`
  when the id is malformed, names an account the subject's user has no live
  membership on, or that membership/account/user is suspended or deleted (all
  indistinguishable, so a switch never confirms a tenant exists).

  The `session.account_switched` audit row is written in the same transaction as
  the locked membership read, so a switch that fails validation leaves no trace
  of having succeeded.
  """
  def switch_account(account_id, %Subject{actor: %Users.User{id: user_id}} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_own_account_permission()
           ) do
      if Repo.valid_uuid?(account_id),
        do: commit_account_switch(account_id, user_id, subject),
        else: {:error, :not_found}
    end
  end

  # Deliberately CROSS-account, so no `Authorizer.for_subject/2`: the subject
  # still carries the tenant the operator is LEAVING, which would scope this
  # lookup to the old account and reject every valid switch. Scoping by the
  # requested account id AND the subject's own actor id is the authorization —
  # you can only ever switch into your own membership (the same documented IL-4
  # exception as `list_accounts_for_user/2`). The row lock orders the switch
  # against concurrent suspension/removal: an earlier revocation makes this
  # `:not_found`; a later revocation waits until the audited switch commits.
  defp commit_account_switch(account_id, user_id, %Subject{} = subject) do
    Multi.new()
    |> Multi.run(:membership, fn repo, _changes ->
      Membership.Query.authorized()
      |> Membership.Query.by_account_and_user(account_id, user_id)
      |> Membership.Query.with_preloaded_account()
      |> Membership.Query.with_preloaded_user()
      |> Membership.Query.lock_for_update()
      |> repo.fetch(Membership.Query)
    end)
    |> Multi.insert(:audit, fn %{membership: membership} ->
      Audit.Events.session_account_switched(subject, membership)
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{membership: membership}} -> {:ok, membership}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Whether a membership is currently disabled — the roster's per-row state for
  suspended and directory-deactivated members alike.
  """
  def membership_disabled?(%Membership{} = membership), do: Membership.disabled?(membership)

  @doc """
  Internal — predicate composed by the web session checks (`UserAuth`) /
  sibling contexts, off a `%Users.User{}` with no subject yet. True if every
  membership the user holds is suspended (and they have at least one). Distinct
  from "user has no memberships" — the UI needs to show "your access was
  suspended" rather than send them to onboarding.
  """
  def all_memberships_suspended?(%Users.User{id: user_id}) do
    base =
      Membership.Query.not_deleted()
      |> Membership.Query.not_pending_invitation()
      |> Membership.Query.by_user_id(user_id)

    Repo.exists?(base) and not Repo.exists?(Membership.Query.not_disabled(base))
  end

  @doc """
  Update a membership's role with hierarchy invariants.

  Returns `{:error, :unauthorized}` for forbidden transitions:
    * Only owners can grant or revoke owner.
    * Admins cannot modify owners.
    * Nobody can promote themselves.
    * Nobody can demote/remove the last owner.

  A change that ADDS permissions is a grant, so it is capped at the actor's own
  reach like an invite or an access edit: promoting a member whose runner/pack
  access exceeds the actor's is refused with
  `{:error, :member_runner_access_exceeds_subject}`. A change that only removes
  permissions is a narrowing and stays open.

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
      # A role that carries no runner reach resets it, so this spans two tables
      # and needs a Multi: the nested `fetch_and_update` joins this transaction
      # and keeps only its `:audit`, and the side effects ride the outer commit.
      Multi.new()
      |> Multi.run(:target, fn repo, _changes ->
        lock_runner_access_membership(repo, membership.id, membership.account_id)
      end)
      |> Multi.run(:previous_access, fn repo, %{target: target} ->
        {:ok, load_runner_access(repo, target)}
      end)
      |> Multi.run(:membership, fn repo, _changes ->
        write_membership_role(repo, membership, new_role, subject)
      end)
      |> Multi.run(:credential_revocation, fn repo, %{target: target, membership: updated} ->
        maybe_revoke_reduced_member_credentials(repo, target.role, updated)
      end)
      |> Multi.run(:runner_access, fn repo, %{membership: updated, previous_access: previous} ->
        reset_runner_access_the_role_carries(repo, updated, previous)
      end)
      |> Multi.run(:runner_access_audit, fn repo, changes ->
        insert_runner_access_audit(repo, subject, changes, changes.runner_access)
      end)
      |> Repo.commit_multi(after_commit: &on_membership_role_committed/1)
      |> case do
        {:ok, %{membership: updated}} -> {:ok, updated}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp write_membership_role(repo, %Membership{} = membership, new_role, %Subject{} = subject) do
    Membership.Query.not_deleted()
    |> Membership.Query.by_id(membership.id)
    |> Authorizer.for_subject(subject)
    |> repo.fetch_and_update(Membership.Query,
      with: fn loaded_membership ->
        # The guards judge the row's CURRENT state under the lock — the caller's
        # struct is a stale socket snapshot. `directory_managed` is judged here
        # too, so a stale UI or crafted event can't slip a synced-role change past.
        with :ok <- ensure_role_not_directory_managed(loaded_membership),
             :ok <- ensure_role_change_allowed(loaded_membership, new_role, subject),
             :ok <- ensure_role_change_within_subject_reach(loaded_membership, new_role, subject),
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
      end
    )
  end

  # The membership's own columns come from `Membership.Changeset`; the normalized
  # `user_runner_scopes` rows can only be rewritten here, so both go through
  # `RunnerAccess.for_role/2` and cannot end up describing different reach. A
  # role that keeps its access writes nothing.
  defp reset_runner_access_the_role_carries(
         repo,
         %Membership{} = membership,
         %RunnerAccess{} = previous
       ) do
    access = RunnerAccess.for_role(membership.role, previous)

    if access == previous,
      do: {:ok, previous},
      else: replace_runner_access_rows(repo, membership.id, access)
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

  # after_commit for the SCIM role sync, whose `fetch_and_update` hands back the
  # changeset: refresh the team list and the member's stale web subject, then on
  # a privilege REDUCTION cut their standing API-key delegations.
  # `changeset.data.role` is the locked pre-update role.
  defp on_membership_role_changed(%Membership{} = membership, %Ecto.Changeset{} = changeset) do
    broadcast_membership_role_changed(membership)
    refresh_member_sessions_if_role_changed(changeset.data.role, membership)
  end

  # after_commit for the operator role change, whose Multi carries the locked
  # pre-update row as `:target`. Refresh once when either the role or its carried
  # reach changed, then broadcast the access reset separately for other mounted
  # team pages.
  defp on_membership_role_committed(
         %{target: target, membership: membership, previous_access: previous} = changes
       ) do
    broadcast_membership_role_changed(membership)

    refresh_member_sessions_if_authorization_changed(
      target,
      membership,
      previous,
      changes.runner_access
    )

    if changes.runner_access == previous,
      do: :ok,
      else: broadcast_membership_runner_access_changed(membership)
  end

  # A membership authorization change leaves a mounted LiveView carrying the
  # OLD `%Subject{}` until its socket reconnects. That is unsafe after a
  # reduction and confusing after an expansion, so every real role, runner, or
  # pack access change disconnects the affected user's sockets after commit.
  # The session rows stay intact: the browser reconnects and rebuilds the
  # subject from current membership state.
  defp refresh_member_sessions_if_role_changed(role, %Membership{role: role}), do: :ok

  defp refresh_member_sessions_if_role_changed(_previous_role, %Membership{} = membership),
    do: refresh_member_sessions(membership)

  defp refresh_member_sessions_if_access_changed(access, access, %Membership{}), do: :ok

  defp refresh_member_sessions_if_access_changed(
         %RunnerAccess{},
         %RunnerAccess{},
         %Membership{} = membership
       ),
       do: refresh_member_sessions(membership)

  defp refresh_member_sessions_if_authorization_changed(
         %Membership{role: previous_role},
         %Membership{role: role},
         %RunnerAccess{} = previous_access,
         %RunnerAccess{} = access
       )
       when previous_role == role and previous_access == access,
       do: :ok

  defp refresh_member_sessions_if_authorization_changed(
         %Membership{},
         %Membership{} = membership,
         %RunnerAccess{},
         %RunnerAccess{}
       ),
       do: refresh_member_sessions(membership)

  # A reduced role must retire credentials minted under the old authority. Run
  # dispatch rechecks membership access, but an `:audit_export` bearer otherwise
  # remains usable at authentication and can keep reading the account audit
  # stream. Suspension and removal revoke for the same reason.
  #
  # Authz here is permission-based, not rank-based (`Auth.Role` deliberately has
  # no rank), so "reduction" is a permission-subset test — the new role losing a
  # permission the old one held. An elevation or a no-op keeps the keys.
  defp maybe_revoke_reduced_member_credentials(
         repo,
         old_role,
         %Membership{role: new_role} = membership
       ) do
    if reduced_permissions?(old_role, new_role) do
      ApiKeys.revoke_credentials_for_membership(repo, membership.id)
    else
      {:ok, %{api_keys: 0, device_grants: 0}}
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

  defp broadcast_membership_invitation_accepted(%Membership{} = membership) do
    Emisar.PubSub.broadcast(
      account_team_topic(membership.account_id),
      {:list_changed, :team, "membership.invitation_accepted", membership.user_id}
    )
  end

  defp invitation_accepted_effects(%{accepted: membership} = changes) do
    :ok = broadcast_membership_invitation_accepted(membership)

    after_membership_activation_committed(changes)
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
        if membership.user_id == Subject.actor_id(subject),
          do: {:error, :cannot_self_promote},
          else: {:error, :insufficient_privileges}

      # Can't change the role of someone whose permissions outrank yours.
      not Auth.Permissions.covers_role?(subject, membership.role) ->
        {:error, :insufficient_privileges}

      true ->
        :ok
    end
  end

  # Nondelegation — the cap invitations (`validate_invitation/3`) and access edits
  # (`update_membership_runner_access/3`) already run: you may not hand out reach
  # you don't hold yourself. A role change carries no access of its own, so only a
  # change that ADDS permissions is a grant, and what the stronger role would
  # wield is the member's EXISTING runner and pack access, read here under the
  # lock. Without this a scoped admin promotes a member whose access exceeds
  # theirs and gains a peer who can widen them right back. A change that only
  # removes permissions is a narrowing and stays open, so a scoped admin can
  # always reduce a member they cannot fully reach. The break-glass staff subject
  # is exempt inside the cap itself, so a support-run promotion is never refused
  # for reach it was never meant to hold.
  defp ensure_role_change_within_subject_reach(
         %Membership{} = membership,
         new_role,
         %Subject{} = subject
       ) do
    if Auth.Permissions.role_covers_role?(membership.role, new_role) do
      :ok
    else
      case ensure_runner_access_grant_allowed(subject, load_runner_access(Repo, membership)) do
        :ok ->
          :ok

        {:error, :runner_access_exceeds_subject} ->
          {:error, :member_runner_access_exceeds_subject}
      end
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
    if membership_authorized?(membership) do
      owners =
        Membership.Query.authorized()
        |> Membership.Query.by_account_id(membership.account_id)
        |> Membership.Query.by_role(:owner)
        |> Membership.Query.lock_for_update()
        |> Repo.all()

      if length(owners) > 1, do: :ok, else: {:error, :last_owner}
    else
      :ok
    end
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
      result =
        Multi.new()
        |> Multi.run(:target, fn repo, _changes ->
          loaded =
            Membership.Query.not_deleted()
            |> Membership.Query.by_id(membership.id)
            |> Membership.Query.lock_for_update()
            |> Authorizer.for_subject(subject)
            |> repo.peek()

          case loaded do
            %Membership{} = loaded_membership ->
              # The guards judge the row's CURRENT role and suspension under
              # the lock — the caller's struct is a stale socket snapshot. A
              # retry is a no-op so it cannot replace the actor who placed the
              # live hold.
              with :ok <- ensure_can_modify_membership(loaded_membership, subject),
                   :ok <- ensure_not_suspended(loaded_membership),
                   :ok <- ensure_not_last_active_owner(loaded_membership) do
                {:ok, loaded_membership}
              end

            nil ->
              {:error, :not_found}
          end
        end)
        |> Multi.update(:membership, fn %{target: loaded_membership} ->
          Membership.Changeset.suspend(loaded_membership, Subject.user_id(subject))
        end)
        |> Multi.insert(:audit, fn %{membership: suspended} ->
          Audit.Events.membership_suspended(subject, suspended)
        end)
        |> Multi.run(:credential_revocation, fn repo, %{membership: suspended} ->
          ApiKeys.revoke_credentials_for_membership(repo, suspended.id)
        end)
        |> Repo.commit_multi(
          after_commit: fn %{membership: suspended} ->
            # Broadcast first so the team-page LV refreshes the row before we
            # kill the user's sessions — keeps the visual ordering sane.
            :ok = broadcast_membership_suspended(suspended)
            :ok = end_account_sessions(suspended)
          end
        )

      case result do
        {:error, {:noop, %Membership{} = loaded_membership}} -> {:ok, loaded_membership}
        {:ok, %{membership: suspended}} -> {:ok, suspended}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Re-enable a previously suspended member. Same authorization shape as suspend.

  A member the directory (SCIM) has deactivated (`directory_suspended` — set by the
  SCIM deprovision write path) is refused with `{:error, :deactivated_in_idp}`:
  reinstating them would grant emisar access the IdP revoked. Reactivation must
  happen in the IdP (its `active: true` re-sync composes through
  `put_sync_membership_lifecycle/4`). The flag lives on the membership, so the
  domain enforces this itself off the locked row — no caller-supplied hint, no
  cycle.
  """
  def reinstate_membership(%Membership{} = membership, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_team_permission()),
         :ok <- ensure_subject_in_account(subject, membership.account_id) do
      Multi.new()
      |> Multi.run(:membership_target, fn repo, _changes ->
        loaded =
          Membership.Query.not_deleted()
          |> Membership.Query.by_id(membership.id)
          |> Membership.Query.lock_for_update()
          |> Authorizer.for_subject(subject)
          |> repo.peek()

        case loaded do
          %Membership{} = loaded_membership ->
            with :ok <- ensure_not_deactivated_in_idp(loaded_membership),
                 :ok <- ensure_can_modify_membership(loaded_membership, subject) do
              {:ok, loaded_membership}
            end

          nil ->
            {:error, :not_found}
        end
      end)
      |> Multi.update(:membership, fn %{membership_target: loaded_membership} ->
        Membership.Changeset.reinstate(loaded_membership)
      end)
      |> Multi.insert(:audit, fn %{membership: reinstated} ->
        Audit.Events.membership_reinstated(subject, reinstated)
      end)
      |> Multi.merge(fn %{membership: reinstated} ->
        put_membership_activation_consequence(Multi.new(), reinstated)
      end)
      |> Repo.commit_multi(after_commit: &manual_membership_reinstated_effects/1)
      |> case do
        {:ok, %{membership: reinstated}} -> {:ok, reinstated}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp manual_membership_reinstated_effects(%{membership: membership} = changes) do
    :ok = broadcast_membership_reinstated(membership)
    after_membership_activation_committed(changes)
  end

  defp sync_suspend_change(%Membership{} = membership, provider) do
    # Guards judge the locked row: it must live in the provider's account
    # (the directory-sync authz boundary), and a deprovision can never lock out
    # the account's last owner. An ALREADY-suspended row is a no-op — crucially,
    # the directory never takes ownership of a MANUAL break-glass suspend.
    with :ok <- ensure_membership_in_provider_account(membership, provider),
         :ok <- ensure_not_suspended(membership),
         :ok <- ensure_not_last_active_owner(membership) do
      Membership.Changeset.sync_suspend(membership, provider.id)
    else
      {:error, reason} -> reason
    end
  end

  @doc """
  Internal — directory sync: the post-commit side effects of a COMMITTED sync
  suspend. Broadcast first so the team-page LV refreshes the row before the
  member's sessions die, then end this account's sessions. Durable credential
  revocation is part of `put_sync_membership_lifecycle/4`; only external effects
  stay here so a later rollback cannot leave the member signed out.
  """
  def membership_suspended_effects(%Membership{} = membership) do
    :ok = broadcast_membership_suspended(membership)
    :ok = end_account_sessions(membership)
  end

  # Only the sessions THIS account authenticated. Revoking every session token the
  # person holds signed them out of every other workspace they belong to — one
  # tenant reaching into another's browser. Their membership here is already
  # suspended or gone, and a session re-resolves its membership on the next
  # request, so nothing outlives this.
  defp end_account_sessions(%Membership{} = membership) do
    SSO.end_account_sessions_for_user(membership.user_id, membership.account_id)
    :ok
  end

  defp ensure_not_suspended(%Membership{disabled_at: nil}), do: :ok
  defp ensure_not_suspended(%Membership{} = membership), do: {:error, {:noop, membership}}

  defp sync_reinstate_change(%Membership{} = membership, provider) do
    # The locked row must live in the provider's account before we write, and
    # the directory only lifts suspensions IT owns. A manual suspension stays a
    # break-glass hold that only an operator can lift.
    with :ok <- ensure_membership_in_provider_account(membership, provider),
         :ok <- ensure_directory_suspended(membership),
         :ok <- ensure_directory_owner(membership, provider) do
      Membership.Changeset.reinstate(membership)
    else
      {:error, reason} -> reason
    end
  end

  @doc """
  Internal — compose one SCIM suspend or reinstate into a caller's transaction.
  The membership update and its audit row become top-level Multi results, so the
  outer `Repo.commit_multi/2` broadcasts only after its provider fence commits.
  Suspend preserves the last-owner guard and manual holds; reinstate lifts only
  a hold owned by this exact provider. An unchanged transition writes no row or
  audit and produces no effect.
  Returns the Multi with `:membership_transition` set to `%{membership, effect}`.
  """
  def put_sync_membership_lifecycle(
        %Multi{} = multi,
        %Membership{} = membership,
        %SSO.IdentityProvider{} = provider,
        action
      )
      when action in [:suspend, :reinstate] do
    multi
    |> Multi.run(:lifecycle_target, fn repo, _changes ->
      Membership.Query.not_deleted()
      |> Membership.Query.by_id(membership.id)
      |> Membership.Query.lock_for_update()
      |> repo.fetch(Membership.Query)
    end)
    |> Multi.run(:lifecycle_plan, fn _repo, %{lifecycle_target: target} ->
      case sync_lifecycle_change(target, provider, action) do
        %Ecto.Changeset{} = changeset -> {:ok, {:changed, changeset}}
        {:noop, %Membership{} = unchanged} -> {:ok, {:unchanged, unchanged}}
        reason -> {:error, reason}
      end
    end)
    |> Multi.merge(fn %{lifecycle_plan: plan} ->
      put_sync_lifecycle_write(plan, provider, action)
    end)
    |> Multi.run(:membership_transition, fn _repo, changes ->
      effect =
        case changes.lifecycle_plan do
          {:changed, _changeset} -> {lifecycle_effect(action), changes.lifecycle_membership}
          {:unchanged, _membership} -> nil
        end

      {:ok, %{membership: changes.lifecycle_membership, effect: effect}}
    end)
    |> Multi.run(:lifecycle_credential_revocation, fn repo,
                                                      %{membership_transition: transition} ->
      case transition.effect do
        {:suspended, %Membership{} = suspended} ->
          ApiKeys.revoke_credentials_for_membership(repo, suspended.id)

        _ ->
          {:ok, %{api_keys: 0, device_grants: 0}}
      end
    end)
    |> Multi.merge(fn %{membership_transition: transition} ->
      case transition.effect do
        {:reinstated, membership} ->
          put_membership_activation_consequence(Multi.new(), membership)

        _ ->
          Multi.run(Multi.new(), :retired_bindings, fn _repo, _changes ->
            {:ok, %{count: 0, socket_topics: []}}
          end)
      end
    end)
  end

  defp sync_lifecycle_change(membership, provider, :suspend),
    do: sync_suspend_change(membership, provider)

  defp sync_lifecycle_change(membership, provider, :reinstate),
    do: sync_reinstate_change(membership, provider)

  defp put_sync_lifecycle_write({:changed, changeset}, provider, action) do
    Multi.new()
    |> Multi.update(:lifecycle_membership, changeset)
    |> Multi.insert(:lifecycle_audit, fn %{lifecycle_membership: updated} ->
      lifecycle_audit(updated, provider, action)
    end)
  end

  defp put_sync_lifecycle_write({:unchanged, membership}, _provider, _action) do
    Multi.new()
    |> Multi.run(:lifecycle_membership, fn _repo, _changes -> {:ok, membership} end)
    |> Multi.run(:lifecycle_audit, fn _repo, _changes -> {:ok, nil} end)
  end

  defp lifecycle_audit(membership, provider, :suspend),
    do: Audit.Events.membership_deprovisioned_via_scim(membership, provider)

  defp lifecycle_audit(membership, provider, :reinstate),
    do: Audit.Events.membership_reprovisioned_via_scim(membership, provider)

  defp lifecycle_effect(:suspend), do: :suspended
  defp lifecycle_effect(:reinstate), do: :reinstated

  @doc """
  Internal — directory sync: the post-commit side effect of a COMMITTED sync
  reinstate (the team-page broadcast). See `membership_suspended_effects/1`
  for why it is not fired inside the write.
  """
  def membership_reinstated_effects(%Membership{} = membership),
    do: broadcast_membership_reinstated(membership)

  @doc "Fire a composed membership lifecycle's external effects after its outer commit."
  def membership_lifecycle_effects(%{membership_transition: transition} = changes) do
    case transition.effect do
      {:suspended, membership} -> membership_suspended_effects(membership)
      {:reinstated, membership} -> membership_reinstated_effects(membership)
      nil -> :ok
    end

    after_membership_activation_committed(changes)
  end

  defp ensure_directory_suspended(%Membership{directory_suspended: true}), do: :ok
  defp ensure_directory_suspended(%Membership{} = membership), do: {:error, {:noop, membership}}

  # An account can run more than one connection. A suspension belongs to the one
  # that placed it, so a second connection re-activating the same person cannot
  # lift it — its `active: true` is news about ITS directory, not this one's. A
  # membership no connection has claimed stays open to whichever acts first,
  # matching `Membership.Query.by_directory_provider_or_unmanaged/2`.
  defp ensure_directory_owner(%Membership{directory_provider_id: nil}, _provider), do: :ok

  defp ensure_directory_owner(%Membership{directory_provider_id: id}, %SSO.IdentityProvider{
         id: id
       }),
       do: :ok

  defp ensure_directory_owner(%Membership{} = membership, _provider),
    do: {:error, {:noop, membership}}

  @doc """
  Internal - SCIM's one locked authorization write. Role and runner access are
  recomputed from the same directory snapshot, persisted in one transaction,
  and marked directory-managed together. The provider account is the authority.
  """
  def sync_set_membership_authorization(
        %Membership{} = membership,
        role,
        %RunnerAccess{} = granted,
        %SSO.IdentityProvider{} = provider
      ) do
    Multi.new()
    |> put_sync_membership_authorization(membership, role, granted, provider)
    |> Repo.commit_multi(after_commit: &after_sync_membership_authorization_committed/1)
    |> case do
      {:ok, %{membership: updated}} -> {:ok, updated}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Internal — compose one directory-owned membership authorization transition
  into a caller's transaction. The caller owns the outer commit and must invoke
  `after_sync_membership_authorization_committed/1` afterwards. Durable
  credential revocation joins the write; PubSub and session refresh wait until
  the outer commit.

  One invocation per Multi: its operation names are the stable shape the
  standalone `sync_set_membership_authorization/4` returns to its callback.
  """
  def put_sync_membership_authorization(
        %Multi{} = multi,
        %Membership{} = membership,
        role,
        %RunnerAccess{} = granted,
        %SSO.IdentityProvider{} = provider
      ) do
    multi
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
    |> Multi.run(:granted_access, fn _repo, %{target: target} ->
      # Role and reach are recomputed from two independent mapping tables, so a
      # directory can map one group to the finance seat and another to runners.
      # The role that will be IN FORCE after this write decides — a synced owner
      # keeps theirs, so their reach is never reset by the seat's rule.
      {:ok, RunnerAccess.for_role(role_in_force(target, role), granted)}
    end)
    |> Multi.update(:membership, fn %{target: target, granted_access: access} ->
      if target.role == :owner do
        Membership.Changeset.sync_runner_authorization(target, access, provider.id)
      else
        Membership.Changeset.sync_authorization(target, role, access, provider.id)
      end
    end)
    |> Multi.run(:authorization_credential_revocation, fn repo,
                                                          %{target: target, membership: updated} ->
      maybe_revoke_reduced_member_credentials(repo, target.role, updated)
    end)
    |> Multi.run(:runner_access, fn repo, %{membership: updated, granted_access: access} ->
      replace_runner_access_rows(repo, updated.id, access)
    end)
    |> Multi.run(:role_audit, fn repo, changes ->
      insert_synced_role_audit(repo, provider, role, changes)
    end)
    |> Multi.run(:runner_access_audit, fn repo, changes ->
      insert_synced_runner_access_audit(repo, provider, changes.granted_access, changes)
    end)
  end

  @doc "Fire a composed directory authorization's external effects after its outer commit."
  def after_sync_membership_authorization_committed(%{} = changes),
    do: on_membership_authorization_synced(changes)

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
      refresh_member_sessions_if_authorization_changed(
        previous_membership,
        membership,
        previous_access,
        access
      )
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
        %Membership{} = membership,
        role,
        %SSO.IdentityProvider{} = provider
      ) do
    Multi.new()
    |> Multi.run(:target, fn repo, _changes ->
      loaded =
        Membership.Query.not_deleted()
        |> Membership.Query.by_id(membership.id)
        |> Membership.Query.lock_for_update()
        |> repo.peek()

      case loaded do
        %Membership{} = loaded_membership ->
          # The guards judge the locked row — the caller's struct is a stale
          # snapshot. It must live in the provider's account, owner stays a
          # human assignment, and we never demote the account's last owner.
          with :ok <- ensure_membership_in_provider_account(loaded_membership, provider),
               :ok <- ensure_sync_role_assignable(role),
               :ok <- ensure_demotion_keeps_an_owner(loaded_membership, role) do
            {:ok, loaded_membership}
          end

        nil ->
          {:error, :not_found}
      end
    end)
    |> Multi.update(:membership, fn %{target: loaded_membership} ->
      Membership.Changeset.sync_role(loaded_membership, role)
    end)
    |> Multi.run(:audit, fn repo, %{target: target, membership: updated} ->
      if target.role == updated.role do
        {:ok, nil}
      else
        target
        |> Audit.Events.membership_role_synced_via_scim(provider, updated.role)
        |> repo.insert()
      end
    end)
    |> Multi.run(:credential_revocation, fn repo, %{target: target, membership: updated} ->
      maybe_revoke_reduced_member_credentials(repo, target.role, updated)
    end)
    |> Repo.commit_multi(after_commit: &after_sync_membership_role_committed/1)
    |> case do
      {:ok, %{membership: updated}} -> {:ok, updated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp after_sync_membership_role_committed(%{target: target, membership: updated}) do
    if target.role != updated.role or target.directory_managed != updated.directory_managed do
      on_membership_role_changed(updated, Ecto.Changeset.change(target, role: updated.role))
    else
      :ok
    end
  end

  @doc """
  Internal — SCIM disable: return role control to operators by clearing the
  `directory_managed` flag on the memberships of `user_ids` (a provider's synced
  members) in `account_id`. No `%Subject{}` — the SSO caller is already authorized
  by the provider's account scope. Returns `{count, nil}`.
  """
  def clear_directory_managed_for_users(account_id, provider_id, user_ids)
      when is_binary(account_id) and is_binary(provider_id) and is_list(user_ids) do
    Membership.Query.not_deleted()
    |> Membership.Query.by_account_id(account_id)
    |> Membership.Query.by_user_ids(user_ids)
    # Only rows THIS connection owns. An account can run several, and clearing
    # every row for a user let tearing down connection B erase the suspension
    # connection A had placed — after which a local admin could reinstate access
    # A still says is revoked.
    |> Membership.Query.by_directory_provider_or_unmanaged(provider_id)
    |> Repo.update_all(
      set: [
        directory_managed: false,
        runner_access_directory_managed: false,
        directory_provider_id: nil,
        directory_authorization_pending_version: nil,
        # The name goes with the directory that supplied it. Left set, the person
        # kept being called whatever the IdP called them in this account forever,
        # and their own profile name could never take over again — a rename after
        # the disable made the split permanent.
        directory_display_name: nil,
        # The suspension STAYS — the directory's last word was that this person is
        # out — but it stops being the directory's to lift, because there is no
        # longer a directory to lift it. Left set, `reinstate_membership` refused
        # with :deactivated_in_idp against an IdP that no longer exists here, and
        # the member could never be recovered by anyone.
        directory_suspended: false,
        updated_at: DateTime.utc_now()
      ]
    )
  end

  # Directory sync can never grant owner — owner stays a deliberate human
  # assignment (decision 7). The group→role mapping changeset already excludes
  # it; this is the write-path backstop.
  defp ensure_sync_role_assignable(:owner), do: {:error, :owner_not_assignable}
  defp ensure_sync_role_assignable(_role), do: :ok

  # `ensure_synced_role_transition/2` lets a synced owner through unchanged, and
  # `sync_runner_authorization/4` then writes their reach without their role — so
  # the role a sync leaves in force is the owner's own, not the directory's.
  defp role_in_force(%Membership{role: :owner}, _synced_role), do: :owner
  defp role_in_force(%Membership{}, synced_role), do: synced_role

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
  Verify the acting administrator's current local TOTP or recovery code and
  return the short-lived, purpose-bound proof for resetting `membership`'s MFA.
  Authorization and target state are checked before spending the factor; the
  eventual reset repeats every check under fresh locks.
  """
  def verify_member_mfa_reset(
        %Membership{} = membership,
        factor,
        actor_session_token_digest,
        %Subject{} = subject
      ) do
    with true <- is_binary(actor_session_token_digest),
         {:ok, %{target: target, target_user: target_user}} <-
           prepare_member_mfa_reset(membership, subject),
         {:ok, local_proof} <- Auth.verify_current_session_mfa_challenge(factor, subject) do
      Auth.issue_member_mfa_reset_proof(
        target,
        target_user,
        {:local, local_proof},
        actor_session_token_digest,
        subject
      )
    else
      false -> {:error, :mfa_reset_proof_stale}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Internal — after the dedicated SSO reauthentication callback proves the
  acting session's exact current identity, issue the same target-bound reset
  handoff used by local MFA. The final mutation rechecks the provider and
  identity while holding their locks.
  """
  def issue_member_mfa_reset_sso_proof(
        %Membership{} = membership,
        %{} = reauthentication,
        actor_session_token_digest,
        %Subject{} = subject
      ) do
    with true <- is_binary(actor_session_token_digest),
         {:ok, %{target: target, target_user: target_user}} <-
           prepare_member_mfa_reset(membership, subject),
         :ok <-
           ensure_member_mfa_reset_started_target(
             reauthentication,
             target,
             target_user
           ) do
      Auth.issue_member_mfa_reset_proof(
        target,
        target_user,
        {:sso, reauthentication},
        actor_session_token_digest,
        subject
      )
    else
      false -> {:error, :mfa_reset_proof_stale}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Reset another member's enrolled second factor after a fresh, reset-specific
  proof. The proof is bound to the actor, account, target membership/user, and
  the target's exact MFA enrollment epoch and row version. The final transaction
  locks and rechecks the current actor membership, hierarchy, factor source, and
  target state before clearing the factor, deleting every target session, and
  auditing `user.mfa_reset_by_admin`.

  Target socket disconnects run only after commit. A rollback leaves the factor,
  sessions, and proof usable for an honest retry.
  """
  def reset_member_mfa(
        %Membership{} = membership,
        proof,
        actor_session_token_digest,
        %Subject{} = subject
      ) do
    with :ok <- ensure_member_mfa_reset_subject(membership, subject),
         {:ok, payload} <- Auth.verify_member_mfa_reset_proof(proof),
         :ok <-
           ensure_member_mfa_reset_binding(
             payload,
             membership,
             actor_session_token_digest,
             subject
           ) do
      Multi.new()
      |> Multi.run(:account, fn repo, _changes ->
        fetch_and_lock_account(membership.account_id, repo: repo)
      end)
      |> Multi.run(:reauthentication, fn repo, _changes ->
        ensure_member_mfa_reset_source_current(repo, payload.source, subject)
      end)
      |> Multi.run(:reset_memberships, fn repo, %{account: account} ->
        lock_member_mfa_reset_memberships(repo, membership, subject, account)
      end)
      |> Multi.run(:reset_users, fn repo, %{reset_memberships: reset_memberships} ->
        lock_member_mfa_reset_users(repo, reset_memberships, payload)
      end)
      |> Multi.run(:actor_session, fn repo, %{reset_users: %{actor: actor}} ->
        Auth.lock_member_mfa_reset_session(
          repo,
          actor_session_token_digest,
          actor.id,
          payload.source
        )
      end)
      |> Multi.run(:reset_proof, fn _repo,
                                    %{
                                      reset_memberships: reset_memberships,
                                      reset_users: reset_users
                                    } ->
        validate_member_mfa_reset_proof(
          payload,
          reset_memberships,
          reset_users
        )
      end)
      |> Multi.run(:target, fn _repo, %{reset_memberships: %{target: target}} ->
        {:ok, target}
      end)
      |> put_member_mfa_reset_writes(subject)
      |> commit_member_mfa_reset()
    end
  end

  @doc """
  Break-glass support reset for the private colocated administration pack. This
  is deliberately a separate actorless capability, never a nil-proof branch in
  the browser API. It retains the same locked hierarchy, accepted-member,
  target-enrollment, audit, session deletion, and post-commit disconnect rules.
  """
  def reset_member_mfa_for_support(
        %Membership{} = membership,
        %Subject{actor: nil, membership_id: nil} = subject
      ) do
    with :ok <- ensure_member_mfa_reset_subject(membership, subject) do
      Multi.new()
      |> Multi.run(:account, fn repo, _changes ->
        lock_support_account(repo, membership.account_id)
      end)
      |> lock_target_membership(membership, fn target ->
        case ensure_can_modify_membership(target, subject) do
          :ok -> ensure_member_mfa_reset_target(target)
          {:error, reason} -> {:error, reason}
        end
      end)
      |> put_member_mfa_reset_writes(subject)
      |> commit_member_mfa_reset()
    end
  end

  def reset_member_mfa_for_support(%Membership{}, %Subject{}),
    do: {:error, :unauthorized}

  # Break-glass administration deliberately reaches disabled accounts. The
  # browser path keeps using the active-account lock above; support still
  # refuses a deleted account while serializing on the same row.
  defp lock_support_account(repo, account_id) do
    if Repo.valid_uuid?(account_id) do
      Account.Query.not_deleted()
      |> Account.Query.by_id(account_id)
      |> Account.Query.lock_for_update()
      |> repo.fetch(Account.Query)
    else
      {:error, :not_found}
    end
  end

  defp prepare_member_mfa_reset(%Membership{} = membership, %Subject{} = subject) do
    with :ok <- ensure_member_mfa_reset_subject(membership, subject) do
      Multi.new()
      |> Multi.run(:account, fn repo, _changes ->
        fetch_and_lock_account(membership.account_id, repo: repo)
      end)
      |> Multi.run(:reset_memberships, fn repo, %{account: account} ->
        lock_member_mfa_reset_memberships(repo, membership, subject, account)
      end)
      |> Multi.run(:reset_users, fn repo, %{reset_memberships: reset_memberships} ->
        lock_member_mfa_reset_users(repo, reset_memberships, nil)
      end)
      |> Repo.commit_multi()
      |> case do
        {:ok,
         %{
           reset_memberships: %{target: target},
           reset_users: %{target: target_user}
         }} ->
          {:ok, %{target: target, target_user: target_user}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp ensure_member_mfa_reset_subject(%Membership{} = membership, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_team_permission()) do
      ensure_subject_in_account(subject, membership.account_id)
    end
  end

  defp lock_member_mfa_reset_memberships(repo, membership, subject, account) do
    ids = [membership.id, subject.membership_id] |> Enum.filter(&is_binary/1) |> Enum.uniq()

    memberships =
      Membership.Query.not_deleted()
      |> Membership.Query.by_account_id(membership.account_id)
      |> Membership.Query.by_ids(ids)
      |> Membership.Query.ordered_by_id()
      |> Membership.Query.lock_for_update()
      |> repo.all()

    actor = Enum.find(memberships, &(&1.id == subject.membership_id))
    target = Enum.find(memberships, &(&1.id == membership.id))

    with true <- length(memberships) == length(ids),
         %Membership{} <- actor,
         %Membership{} <- target,
         :ok <- ensure_member_mfa_reset_actor(actor),
         current_subject = current_member_mfa_reset_subject(subject, account, actor),
         :ok <-
           Auth.Authorizer.ensure_has_permissions(
             current_subject,
             Authorizer.manage_team_permission()
           ),
         :ok <- ensure_can_modify_membership(target, current_subject),
         :ok <- ensure_member_mfa_reset_target(target) do
      {:ok, %{actor: actor, current_subject: current_subject, target: target}}
    else
      false -> {:error, :not_found}
      nil -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_member_mfa_reset_actor(%Membership{disabled_at: nil} = membership) do
    if membership_invitation_pending?(membership), do: {:error, :unauthorized}, else: :ok
  end

  defp ensure_member_mfa_reset_actor(%Membership{}), do: {:error, :unauthorized}

  defp current_member_mfa_reset_subject(subject, account, actor_membership) do
    Subject.for_user(
      subject.actor,
      account,
      actor_membership,
      subject.context,
      auth_method: subject.auth_method,
      mfa: subject.mfa,
      mfa_enrollment_verified_at: subject.mfa_enrollment_verified_at,
      user_identity_id: subject.user_identity_id
    )
  end

  defp ensure_member_mfa_reset_target(%Membership{} = membership) do
    if membership_invitation_pending?(membership),
      do: {:error, :invitation_pending},
      else: :ok
  end

  defp lock_member_mfa_reset_users(repo, reset_memberships, payload) do
    %{actor: actor_membership, target: target_membership} = reset_memberships

    with {:ok, users} <-
           Users.fetch_and_lock_users_by_ids(
             [actor_membership.user_id, target_membership.user_id],
             repo
           ),
         %Users.User{} = actor <- Enum.find(users, &(&1.id == actor_membership.user_id)),
         %Users.User{} = target <- Enum.find(users, &(&1.id == target_membership.user_id)),
         :ok <- ensure_member_mfa_reset_target_user(target, payload) do
      {:ok, %{actor: actor, target: target}}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_member_mfa_reset_target_user(%Users.User{mfa_enabled_at: nil}, nil),
    do: {:error, :mfa_not_enabled}

  defp ensure_member_mfa_reset_target_user(%Users.User{mfa_enabled_at: %DateTime{}}, nil),
    do: :ok

  defp ensure_member_mfa_reset_target_user(%Users.User{} = user, payload) when is_map(payload) do
    if user.mfa_enabled_at == payload.target_mfa_enabled_at and
         user.updated_at == payload.target_updated_at,
       do: :ok,
       else: {:error, :mfa_reset_proof_stale}
  end

  defp ensure_member_mfa_reset_binding(
         payload,
         membership,
         actor_session_token_digest,
         subject
       ) do
    if payload.actor_id == Subject.actor_id(subject) and
         payload.actor_membership_id == subject.membership_id and
         payload.actor_session_token_digest == actor_session_token_digest and
         payload.account_id == membership.account_id and
         payload.account_id == subject.account.id and
         payload.target_membership_id == membership.id and
         payload.target_user_id == membership.user_id,
       do: :ok,
       else: {:error, :mfa_reset_proof_stale}
  end

  defp ensure_member_mfa_reset_started_target(
         %{
           target_membership_id: target_membership_id,
           target_user_id: target_user_id,
           target_mfa_enabled_at: target_mfa_enabled_at,
           target_updated_at: target_updated_at
         },
         %Membership{id: target_membership_id, user_id: target_user_id},
         %Users.User{
           id: target_user_id,
           mfa_enabled_at: target_mfa_enabled_at,
           updated_at: target_updated_at
         }
       )
       when is_binary(target_membership_id) and is_binary(target_user_id) and
              is_struct(target_mfa_enabled_at, DateTime) and
              is_struct(target_updated_at, DateTime),
       do: :ok

  defp ensure_member_mfa_reset_started_target(_reauthentication, _membership, _user),
    do: {:error, :mfa_reset_proof_stale}

  defp ensure_member_mfa_reset_source_current(_repo, {:local, _proof}, %Subject{}),
    do: {:ok, :local}

  defp ensure_member_mfa_reset_source_current(repo, {:sso, reauthentication}, subject) do
    SSO.ensure_member_mfa_reset_reauthentication_current(
      repo,
      reauthentication,
      Subject.actor_id(subject),
      subject.account.id
    )
  end

  defp ensure_member_mfa_reset_source_current(_repo, _source, %Subject{}),
    do: {:error, :mfa_reset_proof_stale}

  defp validate_member_mfa_reset_proof(
         payload,
         %{actor: actor_membership, target: target_membership},
         %{actor: actor, target: target}
       ) do
    with true <- payload.actor_id == actor.id,
         true <- payload.actor_membership_id == actor_membership.id,
         true <- payload.target_membership_id == target_membership.id,
         true <- payload.target_user_id == target.id,
         true <- payload.target_mfa_enabled_at == target.mfa_enabled_at,
         true <- payload.target_updated_at == target.updated_at,
         :ok <- validate_member_mfa_reset_local_source(payload.source, actor) do
      {:ok, :valid}
    else
      false -> {:error, :mfa_reset_proof_stale}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_member_mfa_reset_local_source({:local, _proof} = source, actor),
    do: Auth.verify_local_member_mfa_reset_source(source, actor)

  defp validate_member_mfa_reset_local_source({:sso, _reauthentication}, _actor), do: :ok

  defp put_member_mfa_reset_writes(multi, subject) do
    multi
    |> Multi.run(:user, fn _repo, %{target: loaded_membership} ->
      Users.reset_user_mfa(loaded_membership.user_id,
        audit: &Audit.Events.user_mfa_reset_by_admin(subject, loaded_membership, &1)
      )
    end)
    |> Multi.run(:socket_topics, fn _repo, %{user: user} ->
      {:ok, Auth.capture_live_socket_topics(user)}
    end)
    |> Multi.run(:tokens, fn _repo, %{user: user} -> Auth.delete_all_session_tokens(user) end)
  end

  defp commit_member_mfa_reset(multi) do
    multi
    |> Repo.commit_multi(
      after_commit: fn %{socket_topics: socket_topics} ->
        Auth.disconnect_live_socket_topics(socket_topics)
        :ok
      end
    )
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, reason} -> {:error, reason}
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
    |> Membership.Query.ordered_by_least_recently_updated()
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
  a teammate's sign-in email would let them request a magic link at an
  address they control. The teammate has to change their own email via
  Profile, which verifies TOTP for MFA users or a one-time code sent to
  their current address before committing the change.

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
      # Users whitelists the editable fields (full_name only — email is
      # deliberately not admin-editable, as described above) and
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
      #
      # The socket topics are CAPTURED before the delete: each one is derived
      # from its `user_tokens` row, so an after-commit lookup finds nothing and
      # silently disconnects no one — the member's cookie dies while their open
      # LiveView keeps working.
      Multi.new()
      |> lock_target_membership(membership, &ensure_can_modify_membership(&1, subject))
      |> Multi.run(:user, fn _repo, %{target: loaded_membership} ->
        Users.fetch_user_by_id(loaded_membership.user_id)
      end)
      |> Multi.run(:socket_topics, fn _repo, %{user: user} ->
        {:ok, Emisar.Auth.capture_live_socket_topics(user)}
      end)
      |> Multi.run(:tokens, fn _repo, %{user: user} ->
        Emisar.Auth.delete_all_session_tokens(user)
      end)
      |> Multi.insert(:audit, fn %{target: loaded_membership, user: user} ->
        Audit.Events.user_sessions_revoked(subject, loaded_membership, user)
      end)
      |> Repo.commit_multi(
        after_commit: fn %{socket_topics: socket_topics} ->
          Emisar.Auth.disconnect_live_socket_topics(socket_topics)
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
      # The staff id on an actorless support subject is audit attribution, not
      # a browser user identity. Such a subject cannot be modifying itself.
      membership.user_id == Subject.user_id(subject) ->
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
      Multi.new()
      |> Multi.run(:target, fn repo, _changes ->
        loaded =
          Membership.Query.not_deleted()
          |> Membership.Query.by_id(membership.id)
          |> Membership.Query.lock_for_update()
          |> Authorizer.for_subject(subject)
          |> repo.peek()

        case loaded do
          %Membership{} = loaded_membership ->
            # The guards judge the row's CURRENT role under the lock — the
            # caller's struct is a stale socket snapshot.
            with :ok <- ensure_delete_membership_allowed(loaded_membership, subject),
                 :ok <- ensure_not_last_active_owner(loaded_membership) do
              {:ok, loaded_membership}
            end

          nil ->
            {:error, :not_found}
        end
      end)
      |> Multi.update(:membership, fn %{target: loaded_membership} ->
        Membership.Changeset.delete(loaded_membership)
      end)
      |> Multi.insert(:audit, fn %{membership: removed} ->
        Audit.Events.membership_removed(subject, removed)
      end)
      |> Multi.run(:credential_revocation, fn repo, %{membership: removed} ->
        ApiKeys.revoke_credentials_for_membership(repo, removed.id)
      end)
      |> Repo.commit_multi(
        after_commit: fn %{membership: removed} ->
          :ok = broadcast_membership_removed(removed)

          # A removed member's mounted session still carries its old Subject
          # until it remounts. Disconnect it after the delete commits; durable
          # credentials were revoked in the same transaction as the tombstone.
          :ok = end_account_sessions(removed)
        end
      )
      |> case do
        {:ok, %{membership: removed}} -> {:ok, removed}
        {:error, reason} -> {:error, reason}
      end
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
  Builds the invitation changeset for one raw submission (`email`, `role`,
  `runner_access_mode`, `scope`) — what the invite form renders and validates
  against. Requires `invite` on memberships.

  A non-empty selected-runner scope is resolved against the account's live
  runners so a stale or foreign pick surfaces on the field; the write
  revalidates under a row lock, so this stays advisory. Every other mode reads
  nothing, keeping the LiveView's mount-time builder query-free.

  Returns `{:ok, %Ecto.Changeset{}}` or `{:error, :unauthorized}`.
  """
  def change_invitation(attrs, %Subject{account: %Account{id: account_id}} = subject)
      when is_map(attrs) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.invite_member_permission()
           ) do
      allowlist = invitation_access_facts(Repo, account_id, attrs, false)
      {:ok, InvitationInput.changeset(attrs, allowlist)}
    end
  end

  @doc """
  Invites a user into the account from one raw invitation submission — the same
  attrs `change_invitation/2` validates.

  If no user with that email exists, an unconfirmed placeholder user is
  created so we have something to hang the membership and invitation
  token off of. Returns
  `{:ok, %{membership: m, user: u, invitation_token: token}}` on success,
  `{:error, %Ecto.Changeset{}}` when the submission is invalid, or
  `{:error, :already_member | :unauthorized | :insufficient_privileges |
  :runner_access_exceeds_subject}`.

  The submission is revalidated against the account's live runner rows as the
  transaction's first step — before the placeholder user, the membership, the
  audit row, or any delivery — so a runner soft-deleted while the operator was
  composing cannot slip into the grant.

  The caller is responsible for sending the invitation email; this
  context only persists the records and mints the token.
  """
  def invite_user_to_account(attrs, %Subject{account: %Account{id: account_id}} = subject)
      when is_map(attrs) do
    # Membership is not plan-metered: collaboration is a deliberate growth
    # lever, while runner capacity remains the paid quantity.
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.invite_member_permission()
           ) do
      {token, token_digest} = Crypto.user_invite_token()

      Multi.new()
      |> Multi.run(:invitation, fn repo, _changes ->
        validate_invitation(repo, attrs, subject)
      end)
      |> Multi.run(:user, fn repo, %{invitation: invitation} ->
        Users.fetch_or_create_and_lock_user_by_email(invitation.email, repo)
      end)
      |> Multi.insert(:membership, fn %{user: user, invitation: invitation} ->
        Membership.Changeset.create(%{
          account_id: account_id,
          user_id: user.id,
          role: invitation.role,
          runner_access_mode: invitation.runner_access.mode,
          pack_access_mode: invitation.runner_access.pack_mode,
          pack_scope_pack_ids: invitation.runner_access.pack_ids,
          # `Subject.user_id/1`, not `subject.actor.id`: the break-glass support
          # subject has no actor, and this is a `belongs_to :invited_by` on users
          # — a platform-run invitation records no human inviter rather than
          # crashing on nil (or hanging an API key's id off a users FK).
          invited_by_id: Subject.user_id(subject),
          invitation_token_digest: token_digest,
          invitation_sent_to: user.email,
          invitation_email_changed_at: user.email_changed_at
        })
      end)
      |> Multi.run(:runner_access, fn repo, %{membership: membership, invitation: invitation} ->
        replace_runner_access_rows(repo, membership.id, invitation.runner_access)
      end)
      |> Multi.insert(:audit, fn %{user: user, invitation: invitation} ->
        Audit.Events.user_invited(subject, user, invitation.role, invitation.runner_access)
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
  Invites a user into the account and emails them the join link.

  Same authorization, persistence, and errors as `invite_user_to_account/2`;
  the raw token is not returned by this workflow. `inviter` is who the email
  is attributed to — passed explicitly because a support subject has no actor.

  Returns `{:ok, %{membership: m, user: u, delivery: delivery}}`, where
  `delivery` is `{:ok, :sent}`, `{:ok, :suppressed}` (the address bounced or
  was marked spam, so nothing was sent), or `{:error, reason}`.
  """
  def invite_user_to_account_and_deliver(
        attrs,
        %{} = inviter,
        %Subject{account: %Account{} = account} = subject
      )
      when is_map(attrs) do
    with {:ok, invitation} <- invite_user_to_account(attrs, subject) do
      {:ok, invited_result(invitation, inviter, account)}
    end
  end

  # The authoritative gate: the SAME input changeset the form uses, rebuilt
  # against the account's live runner rows held under FOR UPDATE, so a
  # concurrent soft-delete serializes behind this invitation rather than
  # landing a grant on a runner that is already gone. Role coverage and
  # nondelegation stay tagged atoms; invalid input comes back as the changeset
  # the LiveView renders inline.
  defp validate_invitation(repo, attrs, %Subject{account: %Account{id: account_id}} = subject) do
    allowlist = invitation_access_facts(repo, account_id, attrs, true)
    changeset = InvitationInput.changeset(attrs, allowlist)

    with {:ok, invitation} <- Ecto.Changeset.apply_action(changeset, :insert),
         :ok <- ensure_invite_permitted(invitation.role, subject),
         :ok <- ensure_runner_access_grant_allowed(subject, invitation.runner_access) do
      {:ok, invitation}
    end
  end

  # `none`/`all` name no runners and `all` packs names none either, so the
  # mount-time form builder reads nothing (IL-18); a malformed selection resolves
  # nothing and the input changeset fails it closed.
  defp invitation_access_facts(repo, account_id, attrs, lock?) do
    RunnerAccess.allowlist(
      invitation_runner_facts(repo, account_id, attrs, lock?),
      invitation_pack_facts(repo, account_id, attrs)
    )
  end

  defp invitation_runner_facts(repo, account_id, attrs, lock?) do
    case RunnerAccess.selection_refs(invitation_scope_values(attrs)) do
      {:ok, {[], []}} -> []
      {:ok, {groups, runner_ids}} -> runner_facts(repo, account_id, groups, runner_ids, lock?)
      {:error, :invalid_runner_access} -> []
    end
  end

  defp invitation_pack_facts(repo, account_id, attrs) do
    case Map.get(attrs, "pack_access_mode") || Map.get(attrs, :pack_access_mode) do
      mode when mode in ["restricted", :restricted] -> account_pack_ids(repo, account_id)
      _mode -> []
    end
  end

  defp invitation_scope_values(attrs) do
    case Map.get(attrs, "runner_access_mode") || Map.get(attrs, :runner_access_mode) do
      mode when mode in ["restricted", :restricted] ->
        List.wrap(Map.get(attrs, "scope") || Map.get(attrs, :scope))

      _mode ->
        []
    end
  end

  # Account-scoped raw SQL for the same reason `validate_runner_access_for_account/2`
  # is: tenancy stays owned here rather than opening an Accounts -> Runners
  # dependency. Bounded by the selection (RunnerAccess caps it at 256 scopes)
  # and fully parameterized.
  defp runner_facts(repo, account_id, groups, runner_ids, lock?) do
    query = """
    SELECT runners.id::text, runners."group"
    FROM runners
    WHERE runners.account_id = $1
      AND runners.deleted_at IS NULL
      AND (runners.id = ANY($2::uuid[]) OR runners."group" = ANY($3::text[]))
    """

    # An id that isn't a UUID resolves to nothing and fails the allowlist; it
    # must not reach the uuid[] parameter, which would raise on the cast.
    dumped_runner_ids = for id <- runner_ids, {:ok, dumped} <- [Ecto.UUID.dump(id)], do: dumped
    params = [Ecto.UUID.dump!(account_id), dumped_runner_ids, groups]

    %{rows: rows} = Ecto.Adapters.SQL.query!(repo, query <> lock_clause(lock?), params)
    Enum.map(rows, fn [id, group] -> %{id: id, group: group} end)
  end

  defp lock_clause(true), do: "FOR UPDATE"
  defp lock_clause(false), do: ""

  # The pack dimension is a name filter, not a foreign key, so an id that stops
  # existing simply stops matching — no lock, and no Accounts -> Catalog
  # dependency for one account-scoped column read (the same reason `runner_facts`
  # stays here).
  defp account_pack_ids(repo, account_id) do
    query = """
    SELECT DISTINCT pack_id
    FROM catalog_pack_versions
    WHERE account_id = $1
    """

    %{rows: rows} = Ecto.Adapters.SQL.query!(repo, query, [Ecto.UUID.dump!(account_id)])
    Enum.map(rows, fn [pack_id] -> pack_id end)
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
            :ok ->
              Membership.Changeset.resend_invitation(
                loaded_membership,
                token_digest,
                loaded_membership.user.email,
                loaded_membership.user.email_changed_at
              )

            {:error, reason} ->
              reason
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

  @doc """
  Resends a pending account invitation and emails the refreshed join link.

  Same authorization, persistence, and errors as
  `resend_account_invitation/2`; the raw token is not returned by this workflow.
  Returns `{:ok, %{membership: m, user: u, delivery: delivery}}` with the
  same `delivery` shapes as `invite_user_to_account_and_deliver/5`.
  """
  def resend_account_invitation_and_deliver(
        %Membership{} = membership,
        %{} = inviter,
        %Subject{account: %Account{} = account} = subject
      ) do
    with {:ok, invitation} <- resend_account_invitation(membership, subject) do
      {:ok, invited_result(invitation, inviter, account)}
    end
  end

  # The membership + token are committed before the send, so the email is a
  # post-commit side effect the caller reports on rather than a step that can
  # undo the invitation. The raw token stays in this delivery workflow — its
  # callers get a verdict, never a link they could relay themselves.
  defp invited_result(invitation, inviter, %Account{} = account) do
    %{membership: membership, user: user, invitation_token: token} = invitation

    delivery =
      case Emisar.Mailers.UserNotifier.deliver_account_invitation(
             user,
             inviter,
             account,
             membership,
             token
           ) do
        {:ok, %{suppressed: true}} -> {:ok, :suppressed}
        {:ok, _sent} -> {:ok, :sent}
        {:error, reason} -> {:error, reason}
      end

    %{membership: membership, user: user, delivery: delivery}
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
      |> Membership.Query.invitation_matches_current_email()
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
      |> Membership.Query.invitation_matches_current_email()
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
  one of their own accounts (they are already authenticated and confirmed, so we
  just clear the token + stamp `invitation_accepted_at`). The accepting user
  must BE the invited user (the membership's `user_id`): a signed-in *different*
  user holding the token (e.g. a forwarded link) must not be able to burn the
  invitation. Returns `{:error, :unauthorized}` otherwise.
  """
  def mark_invitation_accepted(
        %Membership{user_id: user_id} = membership,
        token,
        %Users.User{id: user_id} = user
      )
      when is_binary(token) do
    Multi.new()
    |> put_active_account_lock(membership.account_id, :active_account)
    |> Multi.run(:invited_user, fn repo, _changes ->
      Users.fetch_and_lock_user_by_id(membership.user_id, repo)
    end)
    |> Multi.run(:membership, fn repo, %{invited_user: invited_user} ->
      with {:ok, loaded_membership} <-
             lock_pending_invitation(repo, membership, token, invited_user),
           true <- loaded_membership.user_id == user.id do
        {:ok, loaded_membership}
      else
        _ -> {:error, :not_found}
      end
    end)
    |> Multi.run(:credential_revocation, fn repo, %{membership: membership} ->
      ApiKeys.revoke_credentials_for_membership(repo, membership.id)
    end)
    |> Multi.update(:accepted, fn %{membership: membership} ->
      Membership.Changeset.accept_invitation(membership)
    end)
    |> Multi.merge(fn %{accepted: membership} ->
      put_membership_activation_consequence(Multi.new(), membership)
    end)
    |> Multi.insert(:audit, fn %{accepted: membership} ->
      Audit.Events.membership_invitation_accepted(membership)
    end)
    |> Repo.commit_multi(after_commit: &invitation_accepted_effects/1)
    |> case do
      {:ok, %{accepted: membership}} -> {:ok, membership}
      {:error, reason} -> {:error, reason}
    end
  end

  def mark_invitation_accepted(%Membership{}, _token, %Users.User{}),
    do: {:error, :unauthorized}

  @doc """
  Internal — invitation-accept flow: the accept-invite page is a public route
  and the invitee has no session yet, so no `%Subject{}` exists; possession of
  the invitation token (resolved by `fetch_invitation_by_token/1`) is the
  authorization. Accepts a membership invitation: sets the user's full_name,
  clears the invitation token, marks invitation_accepted_at, and confirms the
  user since acceptance proves they own the email. Wrapped in a transaction so
  a half-accepted state is impossible.
  """
  def accept_invitation(%Membership{} = membership, token, %{} = user_attrs)
      when is_binary(token) do
    Multi.new()
    |> put_active_account_lock(membership.account_id, :active_account)
    |> Multi.run(:invited_user, fn repo, _changes ->
      Users.fetch_and_lock_user_by_id(membership.user_id, repo)
    end)
    # Lock + re-judge the invitation before changing either row: a token burnt between the
    # page mount and this submit (a second link holder racing the first
    # acceptor) must fail :not_found here — before register_invited_user
    # could overwrite the winner's display name.
    |> Multi.run(:membership, fn repo, %{invited_user: invited_user} ->
      lock_pending_invitation(repo, membership, token, invited_user)
    end)
    |> Multi.run(:credential_revocation, fn repo, %{membership: membership} ->
      ApiKeys.revoke_credentials_for_membership(repo, membership.id)
    end)
    |> Multi.run(:user, fn _repo, %{membership: loaded_membership} ->
      Users.register_invited_user(loaded_membership.user, user_attrs)
    end)
    |> Multi.update(:accepted, fn %{membership: membership} ->
      Membership.Changeset.accept_invitation(membership)
    end)
    |> Multi.merge(fn %{accepted: membership} ->
      put_membership_activation_consequence(Multi.new(), membership)
    end)
    |> Multi.insert(:audit, fn %{user: user, accepted: updated} ->
      Audit.Events.user_invitation_accepted(user, updated)
    end)
    |> Repo.commit_multi(after_commit: &invitation_accepted_effects/1)
    |> case do
      {:ok, %{user: user, accepted: updated}} -> {:ok, %{user: user, membership: updated}}
      {:error, reason} -> {:error, reason}
    end
  end

  # `nil` means the invitation is no longer pending (accepted, expired,
  # revoked, or the membership vanished) — the accept races resolve here.
  defp lock_pending_invitation(
         repo,
         %Membership{id: id, account_id: account_id},
         token,
         %Users.User{} = user
       ) do
    digest = Crypto.user_invite_token_digest(token)

    membership =
      Membership.Query.not_deleted()
      |> Membership.Query.by_id(id)
      |> Membership.Query.by_account_id(account_id)
      |> Membership.Query.by_invitation_token_digest(digest)
      |> Membership.Query.pending_invitation()
      |> Membership.Query.invitation_not_expired()
      |> Membership.Query.lock_for_update()
      |> repo.one()

    with %Membership{
           user_id: user_id,
           invitation_sent_to: sent_to,
           invitation_email_changed_at: email_changed_at
         } = membership
         when is_binary(sent_to) and is_struct(email_changed_at, DateTime) <- membership,
         true <- user.id == user_id,
         true <- user.email == sent_to and user.email_changed_at == email_changed_at do
      {:ok, %{membership | user: user}}
    else
      _ -> {:error, :not_found}
    end
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
      Membership.Query.authorized()
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
    Membership.Query.authorized()
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
  Internal — resolves a signed Paddle subscription to its account by customer
  id and, when present, the immutable account id copied from checkout custom
  data. Returns `{:ok, account} | {:error, :not_found | :ambiguous}`.
  """
  def resolve_paddle_subscription_account(customer_id, account_id \\ nil)

  def resolve_paddle_subscription_account(customer_id, account_id)
      when is_binary(customer_id) and is_binary(account_id) do
    if Repo.valid_uuid?(account_id) do
      # Deliberately `all()`, not `not_deleted()`: terminal lifecycle receipts
      # must still resolve after account closure.
      Account.Query.all()
      |> Account.Query.by_id(account_id)
      |> Account.Query.by_paddle_customer_id(customer_id)
      |> Repo.fetch(Account.Query)
    else
      {:error, :not_found}
    end
  end

  def resolve_paddle_subscription_account(customer_id, nil) when is_binary(customer_id) do
    accounts =
      Account.Query.all()
      |> Account.Query.by_paddle_customer_id(customer_id)
      |> Account.Query.limit_to(2)
      |> Repo.all()

    case accounts do
      [account] -> {:ok, account}
      [] -> {:error, :not_found}
      [_first, _second] -> {:error, :ambiguous}
    end
  end

  def resolve_paddle_subscription_account(_customer_id, _account_id),
    do: {:error, :not_found}

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
