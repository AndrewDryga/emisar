defmodule Emisar.BillingManagerRoleTest do
  @moduledoc """
  The billing_manager seat's whole contract in one place: full billing
  control plus the member floor (own account + own profile) and NOTHING
  else — and the delegation rule that falls out of `covers_role?/2`
  (granting it requires `manage_billing`, which only owners hold).
  """
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Approvals, Audit, Billing, Catalog, Fixtures, Policies}
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

    test "sees the member count the usage meters need (the account floor)", %{
      account: account,
      subject: subject
    } do
      assert {:ok, _memberships, _metadata} =
               Accounts.list_memberships_for_account(account, subject)
    end

    test "cannot reach another account's billing", %{subject: subject} do
      other_account = Fixtures.Accounts.create_account()

      assert Billing.billing_summary(other_account, subject) == {:error, :unauthorized}
    end
  end

  describe "denied everywhere else" do
    test "team management", %{account: account, subject: subject} do
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")

      assert Accounts.suspend_membership(member, subject) == {:error, :unauthorized}

      assert Accounts.invite_user_to_account("finance-friend@example.test", "viewer", subject) ==
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

    test "SSO administration and the audit trail", %{subject: subject} do
      assert SSO.list_providers_for_account(subject) == {:error, :unauthorized}
      assert Audit.list_events(subject) == {:error, :unauthorized}
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
               "finance-lead@example.test",
               "billing_manager",
               admin_subject
             ) == {:error, :insufficient_privileges}
    end
  end
end
