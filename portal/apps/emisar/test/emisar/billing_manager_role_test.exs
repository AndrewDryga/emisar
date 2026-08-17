defmodule Emisar.BillingManagerRoleTest do
  @moduledoc """
  The billing_manager seat's whole contract in one place — three things and
  nothing else: full billing control, a READ-ONLY view of the team, and the
  BILLING SLICE of the audit trail. Plus the member floor (own account + own
  profile) and the delegation rule that falls out of `covers_role?/2`
  (granting it requires `manage_billing`, which only owners hold).
  """
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, ApiKeys, Approvals, Audit, Billing, Catalog, Fixtures, Policies}
  alias Emisar.{Runbooks, Runners, Runs, SSO}

  setup do
    account = Fixtures.Accounts.create_account()
    user = Fixtures.Users.create_user()

    Fixtures.Memberships.create_membership(
      account_id: account.id,
      user_id: user.id,
      role: "billing_manager"
    )

    subject = Fixtures.Subjects.subject_for(user, account, role: :billing_manager)
    %{account: account, subject: subject}
  end

  describe "billing access" do
    test "holds manage_billing and reads the billing summary", %{
      account: account,
      subject: subject
    } do
      assert Billing.subject_can_manage_billing?(subject)
      assert {:ok, %{plan: _}} = Billing.billing_summary(account, subject)
    end

    test "cannot reach another account's billing", %{subject: subject} do
      other_account = Fixtures.Accounts.create_account()

      assert Billing.billing_summary(other_account, subject) == {:error, :unauthorized}
    end
  end

  describe "the team, read-only" do
    test "reads the roster and its member facts", %{account: account, subject: subject} do
      Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")

      assert {:ok, memberships, _metadata} =
               Accounts.list_memberships_for_account(account, subject)

      assert length(memberships) == 2

      assert {:ok, _facts, _metadata} =
               Accounts.list_team_member_facts(account, subject)
    end

    test "cannot read another account's roster", %{subject: subject} do
      other_account = Fixtures.Accounts.create_account()

      assert Accounts.list_memberships_for_account(other_account, subject) ==
               {:error, :unauthorized}
    end
  end

  describe "the audit trail, narrowed to billing" do
    setup %{account: account} do
      {:ok, billing_event} = Audit.log(account.id, "subscription.changed", actor_kind: "system")
      {:ok, team_event} = Audit.log(account.id, "membership.role_changed", actor_kind: "system")
      {:ok, runner_event} = Audit.log(account.id, "runner.registered", actor_kind: "system")

      %{billing_event: billing_event, runner_event: runner_event, team_event: team_event}
    end

    test "reaches the trail, and knows the view is narrowed", %{subject: subject} do
      assert Audit.subject_can_view_audit?(subject)
      assert Audit.subject_sees_billing_audit_only?(subject)
    end

    test "lists the billing events and withholds every other type", %{
      billing_event: billing_event,
      subject: subject
    } do
      billing_event_id = billing_event.id

      assert {:ok, [%Audit.Event{id: ^billing_event_id}], _metadata} = Audit.list_events(subject)
    end

    # A crafted filter is still only a filter — `Authorizer.for_subject/2`
    # composes last, so asking for a team event narrows the billing set to zero
    # rather than widening it.
    test "a filter naming a non-billing type returns nothing, not that event", %{
      subject: subject
    } do
      assert {:ok, [], _metadata} =
               Audit.list_events(subject, filter: [event_type: ["membership.role_changed"]])
    end

    test "fetches a billing event by id", %{billing_event: billing_event, subject: subject} do
      billing_event_id = billing_event.id

      assert {:ok, %Audit.Event{id: ^billing_event_id}} =
               Audit.fetch_event_by_id(billing_event.id, subject)
    end

    test "a non-billing event is not found even by exact id", %{
      runner_event: runner_event,
      subject: subject,
      team_event: team_event
    } do
      assert Audit.fetch_event_by_id(team_event.id, subject) == {:error, :not_found}
      assert Audit.fetch_event_by_id(runner_event.id, subject) == {:error, :not_found}
    end

    test "cannot read another account's billing events", %{subject: subject} do
      other_account = Fixtures.Accounts.create_account()

      {:ok, other_event} =
        Audit.log(other_account.id, "subscription.changed", actor_kind: "system")

      assert Audit.fetch_event_by_id(other_event.id, subject) == {:error, :not_found}

      assert {:ok, events, _metadata} = Audit.list_events(subject)
      refute other_event.id in Enum.map(events, & &1.id)
    end

    # Reading the money trail in the console is the seat's job; taking the
    # record OUT of the product is an owner/admin/SIEM act.
    test "cannot export the trail", %{subject: subject} do
      refute Audit.subject_can_export_audit?(subject)
      assert Audit.list_for_export(subject) == {:error, :unauthorized}
      assert Audit.list_events_for_export(subject) == {:error, :unauthorized}
    end
  end

  describe "denied everywhere else" do
    test "team management", %{account: account, subject: subject} do
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")

      assert Accounts.suspend_membership(member, subject) == {:error, :unauthorized}

      assert Accounts.invite_user_to_account(
               Fixtures.Accounts.invitation_attrs(
                 email: "finance-friend@example.test",
                 role: "viewer",
                 runner_access_mode: "all"
               ),
               subject
             ) ==
               {:error, :unauthorized}
    end

    test "runs, runners, and the pack catalog", %{subject: subject} do
      assert Runs.list_recent_runs(subject) == {:error, :unauthorized}
      assert Runners.list_all_runners_for_account(subject) == {:error, :unauthorized}
      assert Catalog.list_pack_versions(subject) == {:error, :unauthorized}
    end

    test "policies, runbooks, and approvals", %{subject: subject} do
      assert Policies.fetch_policy(subject) == {:error, :unauthorized}
      assert Runbooks.list_runbooks(subject) == {:error, :unauthorized}
      assert Approvals.list_pending_approval_requests(subject) == {:error, :unauthorized}
    end

    test "LLM agents", %{subject: subject} do
      assert ApiKeys.list_api_keys_for_account(subject) == {:error, :unauthorized}
      refute ApiKeys.subject_can_view_api_keys?(subject)
      refute ApiKeys.subject_can_issue_quick_key?(subject)
    end

    test "SSO administration", %{subject: subject} do
      assert SSO.list_providers_for_account(subject) == {:error, :unauthorized}
    end
  end

  describe "delegation" do
    test "an owner assigns the role", %{account: account} do
      owner = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")
      owner_subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)

      assert {:ok, %Accounts.Membership{role: :billing_manager}} =
               Accounts.update_membership_role(member, "billing_manager", owner_subject)
    end

    test "an admin cannot assign it — the role grants manage_billing the admin lacks", %{
      account: account
    } do
      admin = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: admin.id,
        role: "admin"
      )

      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")
      admin_subject = Fixtures.Subjects.subject_for(admin, account, role: :admin)

      assert Accounts.update_membership_role(member, "billing_manager", admin_subject) ==
               {:error, :insufficient_privileges}

      assert Accounts.invite_user_to_account(
               Fixtures.Accounts.invitation_attrs(
                 email: "finance-lead@example.test",
                 role: "billing_manager",
                 runner_access_mode: "all"
               ),
               admin_subject
             ) == {:error, :insufficient_privileges}
    end
  end
end
