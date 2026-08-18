defmodule Emisar.AdminTest do
  use Emisar.DataCase, async: true
  alias Emisar.Accounts.Membership
  alias Emisar.{Admin, Audit, Billing, Fixtures}

  describe "job_modules/0" do
    test "every recurrent job is disabled in the test environment" do
      enabled = Enum.filter(Admin.job_modules(), &job_enabled?/1)

      assert enabled == [],
             "these jobs tick inside the test sandbox; disable them in config/test.exs: #{inspect(enabled)}"
    end
  end

  defp job_enabled?(module), do: Emisar.Config.get_env(:emisar, module, [])[:enabled] != false

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

  describe "execute/2" do
    test "erases a user only when the confirmation matches the user id" do
      {user, _account, _subject} = Fixtures.Subjects.owner_subject()

      assert Admin.execute("emisar.admin.user.erase", [
               "user_id=#{user.id}",
               "confirmation=not-the-user-id",
               "reason=typo in the confirmation"
             ]) == {:error, {:unsupported_admin_action, "emisar.admin.user.erase"}}

      assert {:ok, %{id: _}} = Emisar.Users.fetch_user_by_id(user.id)

      assert {:ok, %{erased_user_id: erased}} =
               Admin.execute("emisar.admin.user.erase", [
                 "user_id=#{user.id}",
                 "confirmation=#{user.id}",
                 "reason=verified erasure request"
               ])

      assert erased == user.id
      assert Emisar.Users.fetch_user_by_id(user.id) == {:error, :not_found}
    end

    test "dispatches a private RPC action from ordinary name-value argv" do
      account = Fixtures.Accounts.create_account()

      assert {:ok, result} =
               Admin.execute("emisar.admin.account.show", ["account=#{account.slug}"])

      assert result.id == account.id
      assert result.slug == account.slug
      assert result.billing.plan == "free"
    end

    test "keeps equals signs inside values and invokes support writes as system" do
      account = Fixtures.Accounts.create_account()

      assert {:ok, %{disabled: true}} =
               Admin.execute("emisar.admin.account.disable", [
                 "account=#{account.slug}",
                 "reason=support=verified"
               ])

      assert Emisar.Accounts.fetch_account_by_id(account.id) == {:error, :not_found}

      assert {:ok, %{disabled: false}} =
               Admin.execute("emisar.admin.account.enable", [
                 "account=#{account.slug}",
                 "reason=support=resolved"
               ])

      assert {:ok, _account} = Emisar.Accounts.fetch_account_by_id(account.id)
    end

    # These four run under `support_subject/1`, which has no actor. Every one of
    # them crashed on a nil dereference in the membership guard — the break-glass
    # verbs an operator reaches for during an incident, none of them covered.
    test "runs the member break-glass verbs under an actorless support subject" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")

      user = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "operator"
        )

      args = ["account=#{account.slug}", "member=#{user.email}"]

      assert {:ok, suspended} = Admin.execute("emisar.admin.member.suspend", args)
      assert suspended.id == membership.id
      assert is_nil(Repo.reload!(membership).disabled_by_id)

      # The written row carries no :user preload, so the email has to come from
      # the membership the dispatcher already fetched.
      assert suspended.email == user.email

      assert {:ok, _} = Admin.execute("emisar.admin.member.reinstate", args)
      assert {:ok, _} = Admin.execute("emisar.admin.sessions.revoke", args)
      assert {:ok, _} = Admin.execute("emisar.admin.mfa.reset", args)
    end

    # The support subject holds no membership, so `runner_access_for_subject/1`
    # reads its reach as `none` and the nondelegation cap refused the full runner
    # access this verb hands out. Behind that, the membership insert dereferenced
    # `subject.actor.id` for the inviter attribution, which is nil here too.
    test "invites a member with full runner access from the actorless support subject" do
      account = Fixtures.Accounts.create_account()

      assert {:ok, invited} =
               Admin.execute("emisar.admin.member.invite", [
                 "account=#{account.slug}",
                 "email=locked-out-owner@example.com",
                 "role=admin"
               ])

      assert invited.email == "locked-out-owner@example.com"
      assert invited.role == :admin
      assert invited.invitation_pending
      refute invited.disabled

      membership = Repo.one(Membership)
      assert membership.id == invited.id
      assert membership.runner_access_mode == :all
      # No human invited them — the platform did.
      assert is_nil(membership.invited_by_id)
    end

    # The other invitation verb on the same actorless subject: it mints a fresh
    # join link, so the old one must stop working.
    test "resends a pending invitation from the actorless support subject" do
      account = Fixtures.Accounts.create_account()

      assert {:ok, invited} =
               Admin.execute("emisar.admin.member.invite", [
                 "account=#{account.slug}",
                 "email=stalled-invite@example.com",
                 "role=operator"
               ])

      first_digest = Repo.one(Membership).invitation_token_digest

      assert {:ok, resent} =
               Admin.execute("emisar.admin.invitation.resend", [
                 "account=#{account.slug}",
                 "member=stalled-invite@example.com"
               ])

      assert resent.id == invited.id
      assert resent.email == "stalled-invite@example.com"
      assert resent.invitation_pending
      refute Repo.one(Membership).invitation_token_digest == first_digest
    end

    # Promoting reads the MEMBER's existing access as what the stronger role
    # would wield, and the member holds `all` — more than the support subject's
    # `none` — so the same cap governs this verb.
    test "changes a member role from the actorless support subject" do
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
               Admin.execute("emisar.admin.member.set_role", [
                 "account=#{account.slug}",
                 "member=#{user.email}",
                 "role=admin"
               ])

      assert promoted.id == membership.id
      assert promoted.role == :admin
      assert promoted.email == user.email
    end

    test "transfers ownership and demotes the previous owner" do
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
               Admin.execute("emisar.admin.owner.transfer", [
                 "account=#{account.slug}",
                 "new_owner=#{next_owner.email}",
                 "previous_owner=#{previous_owner.email}"
               ])

      assert promoted.role == :owner
      assert promoted.email == next_owner.email
      assert Repo.reload!(previous_membership).role == :admin
    end

    test "rejects malformed, duplicate, excessive, and non-admin arguments" do
      assert Admin.execute("emisar.admin.account.show", ["account"]) ==
               {:error, :invalid_admin_arguments}

      assert Admin.execute("emisar.admin.account.show", ["account=one", "account=two"]) ==
               {:error, :invalid_admin_arguments}

      assert Admin.execute("emisar.admin.account.show", ["a=1", "b=2", "c=3", "d=4"]) ==
               {:error, :invalid_admin_request}

      assert Admin.execute("linux.uptime", []) == {:error, :invalid_admin_request}
    end

    test "complimentary plans use the existing subscription posture" do
      account = Fixtures.Accounts.create_account()

      assert {:ok, %{plan: "team", source: "complimentary"}} =
               Admin.execute("emisar.admin.plan.grant", [
                 "account=#{account.slug}",
                 "plan=team",
                 "reason=design partner"
               ])

      assert Billing.account_plan(account) == "team"

      assert {:ok, %{subscriptions: subscriptions}} =
               Admin.execute("emisar.admin.analytics.revenue", [])

      assert %{plan: "team", status: "complimentary", accounts: 1} in subscriptions
    end
  end
end
