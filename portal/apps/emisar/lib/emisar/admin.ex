defmodule Emisar.Admin do
  @moduledoc """
  Private administrative command boundary invoked through release RPC.

  The public web and MCP routers never call this context. The colocated private
  pack is the only caller; its arguments have already passed runner validation
  and the action run is the durable audit record.
  """
  alias Emisar.{Accounts, Auth, Billing}
  alias Emisar.Admin.Query
  alias Emisar.Auth.Subject
  alias Emisar.{Mailers, Repo, Users}

  @arg_name ~r/^[a-z][a-z0-9_]*$/
  @job_modules [
    Emisar.Accounts.Jobs.MonthlyReports,
    Emisar.ApiKeys.Jobs.DeviceGrantCleanup,
    Emisar.Approvals.Jobs.ExpireOverdueRequests,
    Emisar.Audit.Jobs.Retention,
    Emisar.Billing.Jobs.SyncPaddleCustomers,
    Emisar.Billing.Jobs.SyncSubscriptions,
    Emisar.Catalog.Jobs.PackVersionRetention,
    Emisar.MCPOperations.Jobs.ReplayRetention,
    Emisar.OAuth.Jobs.Cleanup,
    Emisar.Runs.Jobs.ActionRunRetention,
    Emisar.Runs.Jobs.DispatchTimeout,
    Emisar.Runs.Jobs.EventRetention,
    Emisar.Runs.Jobs.FleetObservability,
    Emisar.SSO.Jobs.AuthorizationReconcile
  ]

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
    accounts = Query.accounts_matching(String.trim(term)) |> Repo.all()
    {:ok, %{accounts: Enum.map(accounts, &account_result/1)}}
  end

  defp dispatch("emisar.admin.account.show", args) do
    with {:ok, account} <- fetch_account(args),
         {:ok, plan} <- Billing.support_plan(account) do
      {:ok, Map.put(account_result(account), :billing, plan)}
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
          if is_nil(user.confirmed_at), do: Auth.deliver_confirmation_instructions(user)
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
         {:ok, result} <- Accounts.resend_account_invitation(membership, target_subject) do
      _ =
        Mailers.UserNotifier.deliver_account_invitation(
          result.user,
          inviter(),
          account,
          result.invitation_token
        )

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
           Accounts.invite_user_to_account(
             email,
             role,
             Accounts.RunnerAccess.all(),
             target_subject
           ) do
      _ =
        Mailers.UserNotifier.deliver_account_invitation(
          result.user,
          inviter(),
          account,
          result.invitation_token
        )

      {:ok, membership_result(result.membership)}
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
    do: mutate_member(args, &Accounts.reset_member_mfa/2)

  defp dispatch(
         "emisar.admin.owner.transfer",
         %{"new_owner" => new_owner} = args
       ) do
    with {:ok, account} <- fetch_account(args),
         target_subject = support_subject(account),
         {:ok, next_owner} <- fetch_membership(account.id, new_owner),
         {:ok, promoted} <- Accounts.update_membership_role(next_owner, "owner", target_subject),
         :ok <- maybe_demote_previous_owner(account, args["previous_owner"], target_subject) do
      {:ok, membership_result(promoted)}
    end
  end

  defp dispatch("emisar.admin.billing.sync", args) do
    with {:ok, account} <- fetch_account(args),
         {:ok, _subscription} <- Billing.sync_subscription_for_support(account) do
      Billing.support_plan(account)
    end
  end

  defp dispatch("emisar.admin.analytics.executive", args), do: analytics_executive(args)

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
    {:ok, %{failures: Query.recent_failures(since(args), 50) |> Repo.all()}}
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
      target_subject = support_subject(account)

      membership
      |> mutation.(target_subject)
      |> normalize_member_mutation(membership)
    end
  end

  defp normalize_member_mutation({:ok, %Accounts.Membership{} = membership}, _fallback),
    do: {:ok, membership_result(membership)}

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
      email: membership.user && membership.user.email,
      role: membership.role,
      disabled: not is_nil(membership.disabled_at),
      invitation_pending: is_nil(membership.invitation_accepted_at)
    }
  end

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
