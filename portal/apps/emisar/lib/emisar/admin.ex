defmodule Emisar.Admin do
  @moduledoc """
  Emisar staff operations. Two entries, both gated on the global `is_admin`
  flag; neither is a tenant's own surface, so neither carries a `%Subject{}`.

  `execute/2` is the private administrative command boundary invoked through
  release RPC. The public web and MCP routers never call it; the colocated
  private pack is the only caller, its arguments have already passed runner
  validation, and the action run is the authenticated audit record. Mutations
  use an actorless platform subject because the RPC carries no user credential.

  The staff-console reads — `search_accounts/2`, `account_overview/2`,
  `record_account_view/2` — back the web `/admin` LiveViews. Each takes the
  staff `%Users.User{}` as its last positional argument, in the seat a
  `%Subject{}` holds elsewhere: staff hold no membership in the accounts they
  inspect, so there is no subject to scope by, and `ensure_staff/1` runs
  before any row is read. The web boundary additionally requires a session
  that proved MFA against the user's current enrollment.
  """
  alias Emisar.{Accounts, Audit, Auth, Billing}
  alias Emisar.Admin.Query
  alias Emisar.Auth.Subject
  alias Emisar.{Repo, Users}

  @arg_name ~r/^[a-z][a-z0-9_]*$/
  @job_modules [
    Emisar.Accounts.Jobs.MonthlyReports,
    Emisar.ApiKeys.Jobs.DeviceGrantCleanup,
    Emisar.Approvals.Jobs.ExpireOverdueRequests,
    Emisar.Audit.Jobs.Retention,
    Emisar.Auth.Jobs.TokenRetention,
    Emisar.Billing.Jobs.ProcessedEventRetention,
    Emisar.Billing.Jobs.SyncRunnerQuantities,
    Emisar.Billing.Jobs.SyncPaddleCustomers,
    Emisar.Billing.Jobs.SyncSubscriptions,
    Emisar.Catalog.Jobs.PackVersionRetention,
    Emisar.MCPOperations.Jobs.ReplayRetention,
    Emisar.OAuth.Jobs.Cleanup,
    Emisar.Runners.Jobs.InactiveRunnerRetention,
    Emisar.Runbooks.Jobs.AdvanceExecutions,
    Emisar.Runbooks.Jobs.ExecutionRetention,
    Emisar.Runs.Jobs.ActionRunRetention,
    Emisar.Runs.Jobs.DispatchTimeout,
    Emisar.Runs.Jobs.FleetObservability,
    Emisar.SSO.Jobs.AuthorizationReconcile
  ]

  @doc "Every supervised recurrent job, for runtime inspection and test hygiene."
  def job_modules, do: @job_modules

  # -- Staff console reads ---------------------------------------------

  @doc """
  Accounts matching `query_string` — `{:ok, [%Accounts.Account{}]}`, or
  `{:error, :unauthorized}` when the caller is not staff.

  Matches account name, account slug, and member email, capped at 25. A blank
  query lists the 20 most recently created accounts instead. Disabled accounts
  are included: staff see the whole platform, and a disabled account is the one
  its owner can no longer open a support case from.
  """
  # IL-3 has no shape for this path: staff hold no membership in the accounts
  # they search, so there is no `%Subject{}` to gate with and no query for
  # `Authorizer.for_subject/2` to narrow — `ensure_staff/1`, run before the
  # read, IS the boundary. Nor is it an `@doc "Internal"` helper: this is the
  # staff console's public API. The moduledoc declares the whole module.
  # credo:disable-for-next-line Emisar.Checks.ContextPublicFnSubject
  def search_accounts(query_string, %Users.User{} = staff_user) when is_binary(query_string) do
    with :ok <- ensure_staff(staff_user) do
      accounts = query_string |> String.trim() |> search_queryable() |> Repo.all()
      {:ok, accounts}
    end
  end

  defp search_queryable(""), do: Query.recent_accounts()
  defp search_queryable(term), do: Query.accounts_matching(term)

  @doc """
  One account's whole support picture — `{:ok, overview}`, `{:error,
  :not_found}`, or `{:error, :unauthorized}` when the caller is not staff.
  The account is found by id or slug, disabled ones included.

  The overview is a map of sections, each carrying whole structs: `:account`,
  `:billing` (`Billing.support_plan/1`), `:members` (memberships with their
  user, suspended and unaccepted invitations included), `:sso` (identity
  providers — an account may hold one per kind), `:fleet` (`:counts` by
  connection state plus up to 50 `:runners`, most recently connected first),
  `:runs` (`:count_30d` and the 10 most recent), `:mcp` (`:active_api_keys`
  and the 30-day `:recent_clients` tally), and `:audit_tail` (the 10 most
  recent audit events).

  `:runs.recent` carries `%Runs.ActionRun{}` structs, so those rows hold the
  customer's argument and output payloads. The console renders run identity,
  status, and timing — never a payload field.
  """
  def account_overview(id_or_slug, %Users.User{} = staff_user) when is_binary(id_or_slug) do
    with :ok <- ensure_staff(staff_user),
         reference = String.trim(id_or_slug),
         {:ok, account} <- Accounts.fetch_account_by_id_or_slug_including_disabled(reference),
         {:ok, billing} <- Billing.support_plan(account) do
      {:ok, overview_sections(account, billing)}
    end
  end

  defp overview_sections(%Accounts.Account{} = account, billing) do
    since = DateTime.add(DateTime.utc_now(), -30, :day)

    %{
      account: account,
      billing: billing,
      members: Query.account_memberships(account.id) |> Repo.all(),
      sso: Query.account_identity_providers(account.id) |> Repo.all(),
      fleet: %{
        counts: Query.account_runner_connection_counts(account.id) |> Repo.one(),
        runners: Query.recent_account_runners(account.id) |> Repo.all()
      },
      runs: %{
        count_30d: aggregate_count(Query.account_runs_since(account.id, since)),
        recent: Query.recent_account_runs(account.id) |> Repo.all()
      },
      mcp: %{
        active_api_keys: Query.active_api_key_count(account.id) |> Repo.one(),
        recent_clients: Query.account_mcp_clients_since(account.id, since) |> Repo.all()
      },
      audit_tail: Query.recent_audit_events(account.id) |> Repo.all()
    }
  end

  @doc """
  Append the staff console's view of `account` to that account's own audit
  trail — `{:ok, %Audit.Event{}}`, `{:error, %Ecto.Changeset{}}` if the row is
  rejected, or `{:error, :unauthorized}` when the caller is not staff. The
  customer seeing this row is the point; see
  `Audit.Events.staff_account_viewed/2`.
  """
  def record_account_view(%Accounts.Account{} = account, %Users.User{} = staff_user) do
    with :ok <- ensure_staff(staff_user) do
      Audit.record(Audit.Events.staff_account_viewed(staff_user, account))
    end
  end

  # `is_admin` is a global staff flag, wholly separate from account roles. The
  # staff console reads ACROSS tenants, so there is no query to narrow the way
  # `Authorizer.for_subject/2` does — this gate is the whole boundary, and it
  # runs before any row is read rather than filtering one afterwards.
  #
  # The verdict is the DATABASE row, never the caller's struct. A connected
  # LiveView holds the `current_user` it mounted with for the life of its
  # socket, so judging that snapshot would let an open staff console keep
  # reading every tenant after the flag was revoked — and revocation is a
  # console/migration write with no session to end. The context is the
  # authorization boundary, so it reads truth rather than memory. The argument
  # match stays as a cheap first clause (a signed-in customer is denied without
  # touching the database); past it, one indexed primary-key read per staff call
  # buys a current answer, which is nothing at single-digit staff scale.
  defp ensure_staff(%Users.User{is_admin: true, id: id}) do
    # Fail closed on everything that is not a live, still-flagged row: a
    # revoked flag, a soft-deleted user (the fetch composes `not_deleted`), and
    # a vanished or unpersisted id all land here.
    case Users.fetch_user_by_id(id) do
      {:ok, %Users.User{is_admin: true}} -> :ok
      _denied -> {:error, :unauthorized}
    end
  end

  defp ensure_staff(_user), do: {:error, :unauthorized}

  # -- Private pack RPC ------------------------------------------------

  @doc "Execute one action from the trusted, colocated private admin pack."
  def execute("emisar.admin." <> _ = action_id, encoded_args)
      when is_list(encoded_args) and length(encoded_args) <= 3 do
    with {:ok, args} <- decode_args(encoded_args) do
      dispatch(action_id, args)
    end
  end

  def execute(_action_id, _encoded_args), do: {:error, :invalid_admin_request}

  defp decode_args(encoded_args) do
    Enum.reduce_while(encoded_args, {:ok, %{}}, fn encoded, {:ok, args} ->
      case String.split(encoded, "=", parts: 2) do
        [name, value] ->
          if Regex.match?(@arg_name, name) and not Map.has_key?(args, name),
            do: {:cont, {:ok, Map.put(args, name, value)}},
            else: {:halt, {:error, :invalid_admin_arguments}}

        _ ->
          {:halt, {:error, :invalid_admin_arguments}}
      end
    end)
  end

  defp dispatch("emisar.admin.account.find", %{"query" => term}) do
    accounts = term |> String.trim() |> Query.accounts_matching() |> Repo.all()
    {:ok, %{accounts: Enum.map(accounts, &account_result/1)}}
  end

  defp dispatch("emisar.admin.account.show", args) do
    with {:ok, account} <- fetch_account(args),
         {:ok, plan} <- Billing.support_plan(account) do
      result = account |> account_result() |> Map.put(:billing, plan)
      {:ok, result}
    end
  end

  defp dispatch(
         "emisar.admin.account.create",
         %{"email" => email, "name" => name, "slug" => slug}
       ) do
    case Accounts.fetch_account_by_id_or_slug_including_disabled(slug) do
      {:ok, account} ->
        {:ok, Map.put(account_result(account), :created, false)}

      {:error, :not_found} ->
        with {:ok, user} <- Users.fetch_or_create_user_by_email(String.trim(email)),
             {:ok, account} <- Accounts.create_account_with_owner(%{name: name, slug: slug}, user) do
          if is_nil(user.confirmed_at),
            do: Auth.deliver_confirmation_instructions(user, account)

          {:ok, account |> account_result() |> Map.put(:created, true)}
        end
    end
  end

  defp dispatch(
         "emisar.admin.plan.grant",
         %{"plan" => plan, "reason" => _reason} = args
       ) do
    with {:ok, account} <- fetch_account(args),
         {:ok, _subscription} <- Billing.grant_complimentary_plan(account, plan) do
      Billing.support_plan(account)
    end
  end

  defp dispatch(
         "emisar.admin.plan.revoke",
         %{"reason" => _reason} = args
       ) do
    with {:ok, account} <- fetch_account(args),
         {:ok, _subscription} <- Billing.revoke_complimentary_plan(account) do
      Billing.support_plan(account)
    end
  end

  defp dispatch(
         "emisar.admin.account.disable",
         %{"reason" => reason} = args
       ),
       do: set_account_disabled(args, true, reason)

  defp dispatch(
         "emisar.admin.account.enable",
         %{"reason" => reason} = args
       ),
       do: set_account_disabled(args, false, reason)

  defp dispatch(
         "emisar.admin.access.diagnose",
         %{"member" => member} = args
       ) do
    with {:ok, account} <- fetch_account(args),
         {:ok, membership} <- fetch_membership(account.id, member) do
      {:ok,
       %{
         account: account_result(account),
         member: membership_result(membership),
         confirmed: not is_nil(membership.user.confirmed_at),
         mfa_enabled: not is_nil(membership.user.mfa_enabled_at),
         active_sessions: Query.user_session_count(membership.user_id) |> Repo.one(),
         active_api_keys: Query.active_api_key_count(account.id, membership.user_id) |> Repo.one()
       }}
    end
  end

  defp dispatch(
         "emisar.admin.invitation.resend",
         %{"member" => member} = args
       ) do
    with {:ok, account} <- fetch_account(args),
         {:ok, membership} <- fetch_membership(account.id, member),
         target_subject = support_subject(account),
         {:ok, result} <-
           Accounts.resend_account_invitation_and_deliver(membership, inviter(), target_subject) do
      {:ok, membership_result(result.membership)}
    end
  end

  defp dispatch(
         "emisar.admin.member.invite",
         %{"email" => email, "role" => role} = args
       ) do
    with {:ok, account} <- fetch_account(args),
         target_subject = support_subject(account),
         {:ok, result} <-
           Accounts.invite_user_to_account_and_deliver(
             %{"email" => email, "role" => role, "runner_access_mode" => "all"},
             inviter(),
             target_subject
           ) do
      # Same as mutate_member: the written row carries no :user preload, and the
      # invitee's address is the whole point of the verb's result.
      {:ok, membership_result(%{result.membership | user: result.user})}
    end
  end

  defp dispatch("emisar.admin.member.suspend", args),
    do: mutate_member(args, &Accounts.suspend_membership/2)

  defp dispatch("emisar.admin.member.reinstate", args),
    do: mutate_member(args, &Accounts.reinstate_membership/2)

  defp dispatch(
         "emisar.admin.member.set_role",
         %{"role" => role} = args
       ) do
    mutate_member(args, &Accounts.update_membership_role(&1, role, &2))
  end

  defp dispatch("emisar.admin.sessions.revoke", args),
    do: mutate_member(args, &Accounts.end_all_sessions_for/2)

  defp dispatch("emisar.admin.mfa.reset", args),
    do: mutate_member(args, &Accounts.reset_member_mfa_for_support/2)

  defp dispatch(
         "emisar.admin.owner.transfer",
         %{"new_owner" => new_owner} = args
       ) do
    with {:ok, account} <- fetch_account(args),
         target_subject = support_subject(account),
         {:ok, next_owner} <- fetch_membership(account.id, new_owner),
         {:ok, promoted} <- Accounts.update_membership_role(next_owner, "owner", target_subject),
         :ok <- maybe_demote_previous_owner(account, args["previous_owner"], target_subject) do
      # Same as mutate_member: the written row carries no :user preload.
      {:ok, membership_result(%{promoted | user: next_owner.user})}
    end
  end

  defp dispatch("emisar.admin.billing.sync", args) do
    with {:ok, account} <- fetch_account(args),
         {:ok, _subscription} <- Billing.sync_subscription_for_support(account) do
      Billing.support_plan(account)
    end
  end

  defp dispatch("emisar.admin.analytics.executive", args),
    do: analytics_executive(args)

  defp dispatch("emisar.admin.analytics.revenue", _args) do
    {:ok, %{subscriptions: Query.subscription_posture() |> Repo.all()}}
  end

  defp dispatch("emisar.admin.analytics.engagement", args),
    do: analytics_engagement(args)

  defp dispatch("emisar.admin.analytics.reliability", args),
    do: analytics_reliability(args)

  defp dispatch("emisar.admin.analytics.mcp", args),
    do: analytics_mcp(args)

  defp dispatch("emisar.admin.analytics.security", args),
    do: analytics_security(args)

  defp dispatch("emisar.admin.analytics.data_quality", _args) do
    {:ok, %{row_counts: Query.table_counts() |> Repo.one()}}
  end

  defp dispatch("emisar.admin.runtime.status", _args) do
    {:ok,
     %{
       node: Atom.to_string(node()),
       release: Application.spec(:emisar, :vsn) |> to_string(),
       system_time: DateTime.utc_now(),
       schedulers_online: :erlang.system_info(:schedulers_online),
       process_count: :erlang.system_info(:process_count)
     }}
  end

  defp dispatch("emisar.admin.runtime.jobs", _args) do
    jobs =
      Enum.map(@job_modules, fn module ->
        pid = :global.whereis_name({Emisar.Jobs.Executors.GloballyUnique, module})
        %{job: inspect(module), leader: is_pid(pid), leader_node: job_node(pid)}
      end)

    {:ok, %{jobs: jobs}}
  end

  defp dispatch("emisar.admin.runtime.database", _args) do
    started = System.monotonic_time()

    case Ecto.Adapters.SQL.query(Repo, "SELECT current_database(), pg_is_in_recovery()", []) do
      {:ok, %{rows: [[database, replica?]]}} ->
        duration =
          System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

        {:ok, %{database: database, replica: replica?, latency_ms: duration}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch("emisar.admin.runtime.recent_failures", args) do
    since = since(args)

    {:ok,
     %{
       since: since,
       groups: Query.non_success_outcome_groups_since(since) |> Repo.all(),
       failures: Query.recent_failures(since, 50) |> Repo.all()
     }}
  end

  defp dispatch(
         "emisar.admin.account.erase",
         %{"account_id" => account_id, "confirmation" => confirmation, "reason" => _reason}
       )
       when account_id == confirmation do
    with {:ok, account} <- Accounts.delete_by_id(account_id) do
      {:ok, %{erased_account_id: account.id}}
    end
  end

  defp dispatch(
         "emisar.admin.user.erase",
         %{"user_id" => user_id, "confirmation" => confirmation, "reason" => _reason}
       )
       when user_id == confirmation do
    with {:ok, user} <- Accounts.erase_user_and_owned_accounts(user_id) do
      {:ok, %{erased_user_id: user.id}}
    end
  end

  defp dispatch(action_id, _args),
    do: {:error, {:unsupported_admin_action, action_id}}

  defp set_account_disabled(args, disabled?, reason) do
    with {:ok, account} <- fetch_account(args),
         target_subject = support_subject(account),
         {:ok, account} <-
           Accounts.set_account_disabled_for_support(
             account.id,
             disabled?,
             reason,
             target_subject
           ) do
      {:ok, account_result(account)}
    end
  end

  defp mutate_member(%{"member" => member} = args, mutation) do
    with {:ok, account} <- fetch_account(args),
         {:ok, membership} <- fetch_membership(account.id, member) do
      membership
      |> mutation.(support_subject(account))
      |> normalize_member_mutation(membership)
    end
  end

  # A mutation returns the row it wrote, which carries no :user preload — the
  # fallback is the membership `mutate_member` fetched WITH its user, so carry
  # that across rather than reporting a member with no email.
  defp normalize_member_mutation({:ok, %Accounts.Membership{} = membership}, fallback),
    do: {:ok, membership_result(%{membership | user: fallback.user})}

  defp normalize_member_mutation({:ok, %Users.User{} = user}, membership),
    do: {:ok, membership_result(%{membership | user: user})}

  defp normalize_member_mutation(:ok, membership), do: {:ok, membership_result(membership)}
  defp normalize_member_mutation({:error, reason}, _membership), do: {:error, reason}

  defp maybe_demote_previous_owner(_account, nil, _subject), do: :ok
  defp maybe_demote_previous_owner(_account, "", _subject), do: :ok

  defp maybe_demote_previous_owner(account, previous_owner, subject) do
    with {:ok, membership} <- fetch_membership(account.id, previous_owner),
         {:ok, _membership} <- Accounts.update_membership_role(membership, "admin", subject) do
      :ok
    end
  end

  defp fetch_account(%{"account" => ref}) when is_binary(ref),
    do: Accounts.fetch_account_by_id_or_slug_including_disabled(String.trim(ref))

  defp fetch_account(_), do: {:error, :account_required}

  defp fetch_membership(account_id, ref) when is_binary(ref) do
    queryable =
      if Repo.valid_uuid?(ref),
        do: Query.membership_by_id(account_id, ref),
        else: Query.membership_by_email(account_id, String.trim(ref))

    Repo.fetch(queryable, Accounts.Membership.Query)
  end

  # Platform support work has no user credential at this RPC boundary. The
  # authenticated action run records who dispatched it; domain audit records it
  # as system work.
  defp support_subject(account) do
    %Subject{
      account: account,
      role: :owner,
      permissions: Auth.Permissions.for_role(:owner)
    }
  end

  defp account_result(account) do
    %{
      id: account.id,
      name: account.name,
      slug: account.slug,
      disabled: not is_nil(account.disabled_at),
      created_at: account.inserted_at
    }
  end

  defp membership_result(membership) do
    %{
      id: membership.id,
      user_id: membership.user_id,
      # `&&` alone does not guard this: an unloaded association is a truthy
      # %Ecto.Association.NotLoaded{}, so reading .email off it raises.
      email: member_email(membership.user),
      role: membership.role,
      disabled: not is_nil(membership.disabled_at),
      invitation_pending: Accounts.membership_invitation_pending?(membership)
    }
  end

  defp member_email(%Users.User{email: email}), do: email
  defp member_email(_), do: nil

  defp inviter, do: %{full_name: "Emisar Support", email: "support@emisar.dev"}

  defp analytics_executive(args) do
    since = since(args)
    statuses = Query.run_statuses_since(since) |> Repo.all()

    {:ok,
     %{
       since: since,
       accounts_created: aggregate_count(Query.count_accounts_since(since)),
       users_created: aggregate_count(Query.count_users_since(since)),
       memberships_created: aggregate_count(Query.count_memberships_since(since)),
       runners_created: aggregate_count(Query.count_runners_since(since)),
       runs: aggregate_count(Query.count_runs_since(since)),
       run_statuses: statuses
     }}
  end

  defp analytics_engagement(args) do
    since = since(args)

    {:ok, %{since: since, active_accounts: Query.active_account_ids_since(since) |> Repo.all()}}
  end

  defp analytics_reliability(args) do
    since = since(args)

    {:ok,
     %{
       since: since,
       statuses: Query.run_statuses_since(since) |> Repo.all(),
       top_actions: Query.top_actions_since(since) |> Repo.all()
     }}
  end

  defp analytics_mcp(args) do
    since = since(args)
    {:ok, %{since: since, clients: Query.mcp_clients_since(since) |> Repo.all()}}
  end

  defp analytics_security(args) do
    since = since(args)
    {:ok, %{since: since, approvals: Query.approval_statuses_since(since) |> Repo.all()}}
  end

  defp aggregate_count(queryable), do: Repo.aggregate(queryable, :count, :id)

  defp since(%{"days" => days}) when is_binary(days) do
    case Integer.parse(days) do
      {days, ""} when days in 1..3650 -> DateTime.add(DateTime.utc_now(), -days, :day)
      _ -> DateTime.add(DateTime.utc_now(), -30, :day)
    end
  end

  defp since(_), do: DateTime.add(DateTime.utc_now(), -30, :day)

  defp job_node(pid) when is_pid(pid), do: pid |> node() |> Atom.to_string()
  defp job_node(_), do: nil
end
