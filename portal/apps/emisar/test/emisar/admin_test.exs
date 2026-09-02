defmodule Emisar.AdminTest do
  use Emisar.DataCase, async: true
  alias Emisar.Accounts.Membership
  alias Emisar.{Admin, Audit, Billing, Fixtures}

  @job_supervisors [
    Emisar.Accounts,
    Emisar.ApiKeys,
    Emisar.Approvals,
    Emisar.Audit,
    Emisar.Auth,
    Emisar.Billing,
    Emisar.Catalog,
    Emisar.MCPOperations,
    Emisar.OAuth,
    Emisar.Runners,
    Emisar.Runbooks,
    Emisar.Runs,
    Emisar.SSO
  ]

  describe "job_modules/0" do
    test "exactly matches the recurrent jobs supervised by every owning context" do
      supervised = supervised_job_modules()

      assert Enum.sort(Admin.job_modules()) == Enum.sort(supervised)
      assert length(supervised) == length(Enum.uniq(supervised))
    end

    test "every recurrent job is disabled in the test environment" do
      enabled = Enum.filter(Admin.job_modules(), &job_enabled?/1)

      assert enabled == [],
             "these jobs tick inside the test sandbox; disable them in config/test.exs: #{inspect(enabled)}"
    end
  end

  defp job_enabled?(module), do: Emisar.Config.get_env(:emisar, module, [])[:enabled] != false

  defp supervised_job_modules do
    Enum.flat_map(@job_supervisors, fn supervisor ->
      {:ok, {_flags, children}} = supervisor.init([])

      children
      |> Enum.map(& &1.id)
      |> Enum.filter(&recurrent_job_module?/1)
    end)
  end

  defp recurrent_job_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__config__, 0)
  end

  defp recurrent_job_module?(_module), do: false

  # These reads are DELIBERATELY cross-account — staff see the whole platform —
  # so §7's cross-account isolation path does not apply here. The denial path is
  # the whole security surface: `is_admin` is the only thing between a signed-in
  # customer and every other tenant's rows.
  describe "search_accounts/2" do
    setup do
      %{staff_user: Fixtures.Users.create_user() |> Fixtures.Users.mark_user_as_staff()}
    end

    test "matches an account by slug", %{staff_user: staff_user} do
      account = Fixtures.Accounts.create_account()
      Fixtures.Accounts.create_account()

      assert {:ok, [found]} = Admin.search_accounts(account.slug, staff_user)
      assert found.id == account.id
    end

    test "matches an account by member email", %{staff_user: staff_user} do
      account = Fixtures.Accounts.create_account()
      member = Fixtures.Users.create_user()
      Fixtures.Memberships.create_membership(account_id: account.id, user_id: member.id)

      assert {:ok, [found]} = Admin.search_accounts(member.email, staff_user)
      assert found.id == account.id
    end

    test "a blank query lists the most recently created accounts", %{staff_user: staff_user} do
      account_one = Fixtures.Accounts.create_account()
      account_two = Fixtures.Accounts.create_account()

      assert {:ok, accounts} = Admin.search_accounts("   ", staff_user)
      assert Enum.map(accounts, & &1.id) == [account_two.id, account_one.id]
    end

    test "finds a disabled account", %{staff_user: staff_user} do
      account = Fixtures.Accounts.create_account() |> Fixtures.Accounts.disable_account()

      assert {:ok, [found]} = Admin.search_accounts(account.slug, staff_user)
      assert found.id == account.id
      assert found.disabled_at == account.disabled_at
    end

    test "denies a caller who is not staff" do
      account = Fixtures.Accounts.create_account()
      member = Fixtures.Users.create_user()

      assert Admin.search_accounts(account.slug, member) == {:error, :unauthorized}
    end

    test "denies a stale struct whose staff flag has since been revoked" do
      account = Fixtures.Accounts.create_account()
      stale_staff_user = Fixtures.Users.create_user() |> Fixtures.Users.mark_user_as_staff()
      Fixtures.Users.revoke_user_staff(stale_staff_user)

      # A connected staff LiveView holds exactly this struct — its mount-time
      # snapshot — for the life of the socket, so the flag it carries outlives
      # the revocation. The three staff reads share one gate, which reads the
      # row instead of believing the argument.
      assert stale_staff_user.is_admin
      assert Admin.search_accounts(account.slug, stale_staff_user) == {:error, :unauthorized}
    end
  end

  describe "account_overview/2" do
    setup do
      %{staff_user: Fixtures.Users.create_user() |> Fixtures.Users.mark_user_as_staff()}
    end

    test "each section carries the account's own rows", %{staff_user: staff_user} do
      account = Fixtures.Accounts.create_account(plan: "team")
      owner = Fixtures.Users.create_user()

      owner_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: owner.id,
          role: "owner"
        )

      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      run = Fixtures.Runs.create_run(account_id: account.id, runner_id: runner.id, source: :mcp)
      Fixtures.ApiKeys.create_api_key(account_id: account.id, created_by_id: owner.id)
      {:ok, event} = Audit.log(account.id, "policy.updated", actor_kind: "user")

      assert {:ok, overview} = Admin.account_overview(account.slug, staff_user)

      assert overview.account.id == account.id
      assert overview.billing.plan == "team"

      assert Enum.map(overview.members, & &1.id) == [owner_membership.id]
      assert Enum.map(overview.members, & &1.user.email) == [owner.email]
      assert Enum.map(overview.sso, & &1.id) == [provider.id]

      assert overview.fleet.counts ==
               %{connected: 1, disconnected: 0, never_connected: 0, disabled: 0}

      assert Enum.map(overview.fleet.runners, & &1.id) == [runner.id]

      assert overview.runs.count_30d == 1
      assert Enum.map(overview.runs.recent, & &1.id) == [run.id]

      assert overview.mcp.active_api_keys == 1
      assert overview.mcp.recent_clients == [%{client: "unknown", runs: 1}]

      assert event.id in Enum.map(overview.audit_tail, & &1.id)
    end

    test "the roster keeps suspended members and unaccepted invitations", %{
      staff_user: staff_user
    } do
      account = Fixtures.Accounts.create_account()

      suspended_membership =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
        |> Fixtures.Memberships.suspend_membership()

      invited_membership =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")

      assert {:ok, overview} = Admin.account_overview(account.slug, staff_user)

      assert Enum.map(overview.members, & &1.id) ==
               [suspended_membership.id, invited_membership.id]

      assert Enum.map(overview.members, &is_nil(&1.invitation_accepted_at)) == [true, true]
    end

    test "an account with nothing in it returns empty sections", %{staff_user: staff_user} do
      account = Fixtures.Accounts.create_account()

      assert {:ok, overview} = Admin.account_overview(account.id, staff_user)

      assert overview.billing ==
               %{
                 plan: "free",
                 subscribed_plan: "free",
                 entitlement_state: :free,
                 source: "free",
                 subscription_status: nil,
                 paddle_subscription_id: nil
               }

      assert overview.members == []
      assert overview.sso == []

      assert overview.fleet ==
               %{
                 counts: %{connected: 0, disconnected: 0, never_connected: 0, disabled: 0},
                 runners: []
               }

      assert overview.runs == %{count_30d: 0, recent: []}
      assert overview.mcp == %{active_api_keys: 0, recent_clients: []}
      assert overview.audit_tail == []
    end

    test "an unknown reference is not found", %{staff_user: staff_user} do
      assert Admin.account_overview("no-such-account", staff_user) == {:error, :not_found}
    end

    test "denies a caller who is not staff" do
      account = Fixtures.Accounts.create_account()
      member = Fixtures.Users.create_user()

      assert Admin.account_overview(account.slug, member) == {:error, :unauthorized}
    end
  end

  describe "record_account_view/2" do
    setup do
      %{staff_user: Fixtures.Users.create_user() |> Fixtures.Users.mark_user_as_staff()}
    end

    test "records the view against the account, labelled by team not person", %{
      staff_user: staff_user
    } do
      account = Fixtures.Accounts.create_account()

      assert {:ok, event} = Admin.record_account_view(account, staff_user)

      assert event.account_id == account.id
      assert event.event_type == "staff.account_viewed"
      assert event.actor_kind == "staff"
      assert event.actor_id == staff_user.id
      assert event.actor_label == "Emisar staff"
      assert event.target_kind == "account"
      assert event.target_id == account.id
      assert event.target_label == account.name
      # The customer's own audit detail card renders payload pairs, so the row
      # names the team and nothing else; `actor_id` is the internal trace.
      assert event.payload == %{}
    end

    test "the account's own owner reads it back from their audit trail", %{
      staff_user: staff_user
    } do
      account = Fixtures.Accounts.create_account()
      membership = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")
      subject = Fixtures.Subjects.membership_subject(membership)

      assert {:ok, event} = Admin.record_account_view(account, staff_user)

      assert {:ok, [read_back], _metadata} =
               Audit.list_events(subject, filter: [event_type: ["staff.account_viewed"]])

      assert read_back.id == event.id
      assert read_back.actor_label == "Emisar staff"
    end

    test "denies a caller who is not staff" do
      account = Fixtures.Accounts.create_account()
      member = Fixtures.Users.create_user()

      assert Admin.record_account_view(account, member) == {:error, :unauthorized}
      refute Repo.one(Audit.Event)
    end
  end

  describe "execute/3" do
    setup do
      %{staff_operator: Fixtures.Users.create_user() |> Fixtures.Users.mark_user_as_staff()}
    end

    test "every private mutation requires an operator label" do
      id = Ecto.UUID.generate()

      mutations = [
        {"emisar.admin.account.create",
         ["email=owner@example.com", "name=Example", "slug=example"]},
        {"emisar.admin.account.disable", ["account=example", "reason=support"]},
        {"emisar.admin.account.enable", ["account=example", "reason=support"]},
        {"emisar.admin.account.erase",
         ["account_id=#{id}", "confirmation=#{id}", "reason=request"]},
        {"emisar.admin.user.erase", ["user_id=#{id}", "confirmation=#{id}", "reason=request"]},
        {"emisar.admin.plan.grant", ["account=example", "plan=team", "reason=partner"]},
        {"emisar.admin.plan.revoke", ["account=example", "reason=ended"]},
        {"emisar.admin.invitation.resend", ["account=example", "member=person@example.com"]},
        {"emisar.admin.member.invite",
         ["account=example", "email=person@example.com", "role=viewer"]},
        {"emisar.admin.member.suspend", ["account=example", "member=person@example.com"]},
        {"emisar.admin.member.reinstate", ["account=example", "member=person@example.com"]},
        {"emisar.admin.member.set_role",
         ["account=example", "member=person@example.com", "role=viewer"]},
        {"emisar.admin.sessions.revoke", ["account=example", "member=person@example.com"]},
        {"emisar.admin.mfa.reset", ["account=example", "member=person@example.com"]},
        {"emisar.admin.owner.transfer", ["account=example", "new_owner=person@example.com"]},
        {"emisar.admin.billing.sync", ["account=example"]}
      ]

      for {action_id, args} <- mutations do
        assert Admin.execute(action_id, args, "") == {:error, :operator_required}, action_id
      end
    end

    test "erases a user only when the confirmation matches the user id", %{
      staff_operator: staff_operator
    } do
      {user, _account, _subject} = Fixtures.Subjects.owner_subject()

      assert Admin.execute(
               "emisar.admin.user.erase",
               [
                 "user_id=#{user.id}",
                 "confirmation=not-the-user-id",
                 "reason=typo in the confirmation"
               ],
               staff_operator.email
             ) == {:error, {:unsupported_admin_action, "emisar.admin.user.erase"}}

      assert {:ok, %{id: _}} = Emisar.Users.fetch_user_by_id(user.id)

      assert {:ok, %{erased_user_id: erased}} =
               Admin.execute(
                 "emisar.admin.user.erase",
                 [
                   "user_id=#{user.id}",
                   "confirmation=#{user.id}",
                   "reason=verified erasure request"
                 ],
                 staff_operator.email
               )

      assert erased == user.id
      assert Emisar.Users.fetch_user_by_id(user.id) == {:error, :not_found}
    end

    test "dispatches a private RPC action from ordinary name-value argv" do
      account = Fixtures.Accounts.create_account()

      assert {:ok, result} =
               Admin.execute("emisar.admin.account.show", ["account=#{account.slug}"], "")

      assert result.id == account.id
      assert result.slug == account.slug
      assert result.billing.plan == "free"
    end

    test "stamps a staff mutation as the team, not the system or a spoofable operator id",
         %{staff_operator: staff_operator} do
      account = Fixtures.Accounts.create_account()

      assert {:ok, %{disabled: true}} =
               Admin.execute(
                 "emisar.admin.account.disable",
                 ["account=#{account.slug}", "reason=support=verified"],
                 staff_operator.email
               )

      # A disabled account's own owner is locked out, so read the trail directly.
      event = Enum.find(Repo.all(Audit.Event), &(&1.event_type == "account.disabled"))

      # The customer's own trail attributes the block to "Emisar staff" — never an
      # anonymous "system" job, and never the operator's specific id, which is an
      # unauthenticated argv claim (one staff member could name another). The
      # authenticated operator stays accountable in Emisar's own dispatch audit.
      # The reason value round-trips its embedded "=" unsplit.
      assert event.actor_kind == "staff"
      assert is_nil(event.actor_id)
      assert event.actor_label == "Emisar staff"
      assert event.payload == %{"reason" => "support=verified"}

      assert {:ok, %{disabled: false}} =
               Admin.execute(
                 "emisar.admin.account.enable",
                 ["account=#{account.slug}", "reason=support=resolved"],
                 staff_operator.email
               )

      assert {:ok, _account} = Emisar.Accounts.fetch_account_by_id(account.id)
    end

    test "refuses a staff mutation whose operator does not resolve to a live staff user",
         %{staff_operator: staff_operator} do
      account = Fixtures.Accounts.create_account()
      member = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: member.id,
          role: "operator"
        )

      args = ["account=#{account.slug}", "member=#{member.email}"]

      # An ordinary account member is not staff; the argv claim naming them is refused.
      assert Admin.execute("emisar.admin.member.suspend", args, member.email) ==
               {:error, :operator_not_staff}

      # A reference that resolves to no user at all.
      assert Admin.execute("emisar.admin.member.suspend", args, "ghost@example.test") ==
               {:error, :unknown_operator}

      # A blank operator cannot authorize a staff mutation.
      assert Admin.execute("emisar.admin.member.suspend", args, "") ==
               {:error, :operator_required}

      refute Repo.reload!(membership).disabled_at

      # A resolvable staff operator, by id, is accepted.
      assert {:ok, _suspended} =
               Admin.execute("emisar.admin.member.suspend", args, staff_operator.id)

      assert Repo.reload!(membership).disabled_at
    end

    test "runs the member break-glass verbs as the resolved staff operator",
         %{staff_operator: staff_operator} do
      account = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")

      user =
        Fixtures.Users.create_user()
        |> Fixtures.Users.set_mfa_state(
          mfa_secret: "JBSWY3DPEHPK3PXP",
          mfa_enabled_at: DateTime.utc_now(),
          mfa_recovery_codes: []
        )

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "operator"
        )

      args = ["account=#{account.slug}", "member=#{user.email}"]

      assert {:ok, suspended} =
               Admin.execute("emisar.admin.member.suspend", args, staff_operator.email)

      assert suspended.id == membership.id
      assert Repo.reload!(membership).disabled_at

      # The written row carries no :user preload, so the email has to come from
      # the membership the dispatcher already fetched.
      assert suspended.email == user.email

      assert {:ok, _} = Admin.execute("emisar.admin.member.reinstate", args, staff_operator.email)
      assert {:ok, _} = Admin.execute("emisar.admin.sessions.revoke", args, staff_operator.email)

      assert {:ok, _} =
               Admin.execute(
                 "emisar.admin.account.disable",
                 ["account=#{account.slug}", "reason=break-glass MFA reset"],
                 staff_operator.email
               )

      assert {:ok, _} = Admin.execute("emisar.admin.mfa.reset", args, staff_operator.email)
    end

    test "invites a member with full runner access as the staff operator",
         %{staff_operator: staff_operator} do
      account = Fixtures.Accounts.create_account()

      assert {:ok, invited} =
               Admin.execute(
                 "emisar.admin.member.invite",
                 ["account=#{account.slug}", "email=locked-out-owner@example.com", "role=admin"],
                 staff_operator.email
               )

      assert invited.email == "locked-out-owner@example.com"
      assert invited.role == :admin
      assert invited.invitation_pending
      refute invited.disabled

      membership = Repo.one(Membership)
      assert membership.id == invited.id
      assert membership.runner_access_mode == :all
      # A platform-run invitation records no member as the inviter.
      assert is_nil(membership.invited_by_id)
    end

    test "resends a pending invitation as the staff operator",
         %{staff_operator: staff_operator} do
      account = Fixtures.Accounts.create_account()

      assert {:ok, invited} =
               Admin.execute(
                 "emisar.admin.member.invite",
                 ["account=#{account.slug}", "email=stalled-invite@example.com", "role=operator"],
                 staff_operator.email
               )

      first_digest = Repo.one(Membership).invitation_token_digest

      assert {:ok, resent} =
               Admin.execute(
                 "emisar.admin.invitation.resend",
                 ["account=#{account.slug}", "member=stalled-invite@example.com"],
                 staff_operator.email
               )

      assert resent.id == invited.id
      assert resent.email == "stalled-invite@example.com"
      assert resent.invitation_pending
      refute Repo.one(Membership).invitation_token_digest == first_digest
    end

    test "changes a member role as the staff operator", %{staff_operator: staff_operator} do
      account = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")
      user = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "viewer"
        )

      assert {:ok, promoted} =
               Admin.execute(
                 "emisar.admin.member.set_role",
                 ["account=#{account.slug}", "member=#{user.email}", "role=admin"],
                 staff_operator.email
               )

      assert promoted.id == membership.id
      assert promoted.role == :admin
      assert promoted.email == user.email
    end

    test "transfers ownership and demotes the previous owner", %{staff_operator: staff_operator} do
      account = Fixtures.Accounts.create_account()
      previous_owner = Fixtures.Users.create_user()

      previous_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: previous_owner.id,
          role: "owner"
        )

      next_owner = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: next_owner.id,
        role: "operator"
      )

      assert {:ok, promoted} =
               Admin.execute(
                 "emisar.admin.owner.transfer",
                 [
                   "account=#{account.slug}",
                   "new_owner=#{next_owner.email}",
                   "previous_owner=#{previous_owner.email}"
                 ],
                 staff_operator.email
               )

      assert promoted.role == :owner
      assert promoted.email == next_owner.email
      assert Repo.reload!(previous_membership).role == :admin
    end

    test "rejects malformed, duplicate, excessive, and non-admin arguments" do
      assert Admin.execute("emisar.admin.account.show", ["account"], "") ==
               {:error, :invalid_admin_arguments}

      assert Admin.execute("emisar.admin.account.show", ["account=one", "account=two"], "") ==
               {:error, :invalid_admin_arguments}

      assert Admin.execute("emisar.admin.account.show", ["a=1", "b=2", "c=3", "d=4"], "") ==
               {:error, :invalid_admin_request}

      # A non-binary operator never satisfies the release-RPC contract.
      assert Admin.execute("emisar.admin.account.show", ["account=x"], nil) ==
               {:error, :invalid_admin_request}

      assert Admin.execute("linux.uptime", [], "") == {:error, :invalid_admin_request}
    end

    test "complimentary plans use the existing subscription posture", %{
      staff_operator: staff_operator
    } do
      account = Fixtures.Accounts.create_account()

      assert {:ok, %{plan: "team", source: "complimentary"}} =
               Admin.execute(
                 "emisar.admin.plan.grant",
                 ["account=#{account.slug}", "plan=team", "reason=design partner"],
                 staff_operator.email
               )

      assert Billing.account_plan(account) == "team"

      assert {:ok, %{subscriptions: subscriptions}} =
               Admin.execute("emisar.admin.analytics.revenue", [], "")

      assert %{plan: "team", status: "complimentary", accounts: 1} in subscriptions
    end

    test "groups terminal non-success outcomes without counting fan-out as operations" do
      account_one = Fixtures.Accounts.create_account()
      account_two = Fixtures.Accounts.create_account()
      runner_one = Fixtures.Runners.create_runner(account_id: account_one.id)
      runner_two = Fixtures.Runners.create_runner(account_id: account_two.id)
      pack_ref = "nomad@0.4.3/sha256:" <> String.duplicate("a", 64)

      shared = %{
        action_id: "nomad.job_health_snapshot",
        source: :mcp,
        status: :failed,
        pack_ref: pack_ref,
        client_info: %{"name" => "Claude Code"}
      }

      for {account, runner, operation_id} <- [
            {account_one, runner_one, "op_724NN9NMDZ1T76NARWCKM5A0D6"},
            {account_one, runner_one, "op_724NN9NMDZ1T76NARWCKM5A0D6"},
            {account_two, runner_two, "op_725NN9NMDZ1T76NARWCKM5A0D6"}
          ] do
        Fixtures.Runs.create_run(
          account_id: account.id,
          runner_id: runner.id,
          action_id: shared.action_id,
          source: shared.source,
          status: shared.status
        )
        |> update_run_analytics!(Map.put(shared, :operation_id, operation_id))
      end

      Fixtures.Runs.create_run(
        account_id: account_one.id,
        runner_id: runner_one.id,
        action_id: shared.action_id,
        source: :mcp,
        status: :denied
      )
      |> update_run_analytics!(%{
        operation_id: "op_726NN9NMDZ1T76NARWCKM5A0D6",
        pack_ref: pack_ref,
        client_info: %{"name" => "Claude Code"}
      })

      Fixtures.Runs.create_run(
        account_id: account_one.id,
        runner_id: runner_one.id,
        action_id: shared.action_id,
        source: :mcp,
        status: :success
      )
      |> update_run_analytics!(%{
        operation_id: "op_727NN9NMDZ1T76NARWCKM5A0D6",
        pack_ref: pack_ref,
        client_info: %{"name" => "Claude Code"}
      })

      assert {:ok, report} =
               Admin.execute("emisar.admin.runtime.recent_failures", ["days=1"], "")

      failed_group = Enum.find(report.groups, &(&1.status == :failed))
      denied_group = Enum.find(report.groups, &(&1.status == :denied))

      assert failed_group.action_id == "nomad.job_health_snapshot"
      assert failed_group.pack_ref == pack_ref
      assert failed_group.source == :mcp
      assert failed_group.client == "Claude Code"
      assert failed_group.run_count == 3
      assert failed_group.operation_count == 2
      assert failed_group.account_count == 2
      assert %DateTime{} = failed_group.last_seen_at

      assert denied_group.status == :denied
      assert denied_group.run_count == 1
      assert denied_group.operation_count == 1
      assert length(report.failures) == 3
      assert Enum.all?(report.failures, &(&1.status == :failed))
      assert %DateTime{} = report.since
    end
  end

  defp update_run_analytics!(run, attrs) do
    run
    |> Ecto.Changeset.change(attrs)
    |> Repo.update!()
  end
end
