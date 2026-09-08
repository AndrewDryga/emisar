defmodule Emisar.PoliciesApprovalRequirementsTest do
  use Emisar.DataCase, async: true
  alias Emisar.Accounts.RunnerAccess
  alias Emisar.{Fixtures, Policies}

  describe "fetch_approval_requirements_summary/1" do
    test "a viewer reads the configured single-approver default" do
      membership = Fixtures.Memberships.create_membership(role: "viewer")
      subject = Fixtures.Subjects.membership_subject(membership)
      Fixtures.Policies.create_policy(account_id: membership.account_id)

      assert Policies.fetch_approval_requirements_summary(subject) ==
               {:ok, %{min_approvals: 1, allow_self_approval: true}}
    end

    test "matching defaults and targeted rulesets keep a concrete requirement" do
      membership = Fixtures.Memberships.create_membership(role: "operator")
      subject = Fixtures.Subjects.membership_subject(membership)
      rules = approval_rules(2, false)
      Fixtures.Policies.create_policy(account_id: membership.account_id, rules: rules)

      Fixtures.Policies.create_policy(
        account_id: membership.account_id,
        scope_type: :group,
        scope_value: "databases",
        rules: rules
      )

      assert Policies.fetch_approval_requirements_summary(subject) ==
               {:ok, %{min_approvals: 2, allow_self_approval: false}}
    end

    test "different runner and group requirements are summarized independently" do
      membership = Fixtures.Memberships.create_membership()
      subject = Fixtures.Subjects.membership_subject(membership)
      runner = Fixtures.Runners.create_runner(account_id: membership.account_id)
      Fixtures.Policies.create_policy(account_id: membership.account_id)

      Fixtures.Policies.create_policy(
        account_id: membership.account_id,
        scope_type: :runner,
        scope_value: runner.id,
        rules: approval_rules(3, true)
      )

      assert Policies.fetch_approval_requirements_summary(subject) ==
               {:ok, %{min_approvals: :varies, allow_self_approval: true}}

      Fixtures.Policies.create_policy(
        account_id: membership.account_id,
        scope_type: :group,
        scope_value: "databases",
        rules: approval_rules(1, false)
      )

      assert Policies.fetch_approval_requirements_summary(subject) ==
               {:ok, %{min_approvals: :varies, allow_self_approval: :varies}}
    end

    test "restricted access includes the default but excludes hidden and foreign targets" do
      membership = Fixtures.Memberships.create_membership(role: "viewer")
      {:ok, access} = RunnerAccess.restricted(["databases"], [])
      Fixtures.Memberships.force_runner_access(membership, access)
      subject = Fixtures.Subjects.membership_subject(membership)
      Fixtures.Runners.create_runner(account_id: membership.account_id, group: "databases")
      hidden = Fixtures.Runners.create_runner(account_id: membership.account_id, group: "web")
      Fixtures.Policies.create_policy(account_id: membership.account_id)

      Fixtures.Policies.create_policy(
        account_id: membership.account_id,
        scope_type: :group,
        scope_value: "databases",
        rules: approval_rules(1, false)
      )

      Fixtures.Policies.create_policy(
        account_id: membership.account_id,
        scope_type: :runner,
        scope_value: hidden.id,
        rules: approval_rules(7, false)
      )

      Fixtures.Policies.create_policy(
        account_id: membership.account_id,
        scope_type: :group,
        scope_value: "web",
        rules: approval_rules(9, false)
      )

      Fixtures.Policies.create_policy(rules: approval_rules(11, false))

      assert Policies.fetch_approval_requirements_summary(subject) ==
               {:ok, %{min_approvals: 1, allow_self_approval: :varies}}
    end

    test "missing default does not borrow another account's settings or invent defaults" do
      membership = Fixtures.Memberships.create_membership()
      subject = Fixtures.Subjects.membership_subject(membership)
      Fixtures.Policies.create_policy(rules: approval_rules(3, false))

      assert Policies.fetch_approval_requirements_summary(subject) == {:error, :not_found}
    end

    test "policy read permission is required" do
      account = Fixtures.Accounts.create_account()
      subject = Fixtures.Subjects.permissionless_subject(account)

      assert Policies.fetch_approval_requirements_summary(subject) == {:error, :unauthorized}
    end

    test "malformed default or targeted settings do not produce an optimistic summary" do
      membership = Fixtures.Memberships.create_membership()
      subject = Fixtures.Subjects.membership_subject(membership)
      default = Fixtures.Policies.create_policy(account_id: membership.account_id)
      Fixtures.Policies.corrupt_approval_settings(default, :missing)

      assert Policies.fetch_approval_requirements_summary(subject) ==
               {:error, :invalid_policy_approval}

      Fixtures.Policies.create_policy(account_id: membership.account_id)

      scoped =
        Fixtures.Policies.create_policy(
          account_id: membership.account_id,
          scope_type: :group,
          scope_value: "databases"
        )

      invalid = [
        :missing,
        "broken",
        %{"min_approvals" => 2, "allow_self_approval" => true, "extra" => true}
      ]

      for approval <- invalid do
        Fixtures.Policies.corrupt_approval_settings(scoped, approval)

        assert Policies.fetch_approval_requirements_summary(subject) ==
                 {:error, :invalid_policy_approval}
      end
    end

    test "the work bound counts distinct configurations, not policies" do
      membership = Fixtures.Memberships.create_membership()
      subject = Fixtures.Subjects.membership_subject(membership)
      Fixtures.Policies.create_policy(account_id: membership.account_id)

      for index <- 1..101 do
        Fixtures.Policies.create_policy(
          account_id: membership.account_id,
          created_by_id: membership.user_id,
          scope_type: :group,
          scope_value: "group-#{index}"
        )
      end

      assert Policies.fetch_approval_requirements_summary(subject) ==
               {:ok, %{min_approvals: 1, allow_self_approval: true}}

      for index <- 1..101 do
        Fixtures.Policies.create_policy(
          account_id: membership.account_id,
          created_by_id: membership.user_id,
          scope_type: :group,
          scope_value: "group-#{index}",
          rules: approval_rules(index, true)
        )
      end

      assert Policies.fetch_approval_requirements_summary(subject) ==
               {:error, :approval_summary_too_complex}
    end
  end

  defp approval_rules(count, self_approval?) do
    Map.put(Policies.default_rules(), "approval", %{
      "min_approvals" => count,
      "allow_self_approval" => self_approval?
    })
  end
end
