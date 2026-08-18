defmodule Emisar.PoliciesPersistenceTest do
  @moduledoc """
  DB-backed coverage for the policy save surface (the pure evaluation
  logic lives in `Emisar.PoliciesTest`): `save_rules/2` both creates the
  account's first policy and updates an existing one, behind the
  manage_policies gate.
  """
  use Emisar.DataCase, async: true
  alias Emisar.Fixtures
  alias Emisar.Policies

  defp rules(high_decision) do
    %{
      "schema_version" => 2,
      "defaults" => %{
        "low" => "allow",
        "medium" => "allow",
        "high" => high_decision,
        "critical" => "deny"
      },
      "overrides" => [],
      "approval" => %{"min_approvals" => 1, "allow_self_approval" => true}
    }
  end

  describe "save_rules/2" do
    test "creates the account's first policy, then updates it in place" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()

      assert {:ok, created} = Policies.save_rules(rules("require_approval"), subject)
      assert created.account_id == account.id
      assert created.rules["defaults"]["high"] == "require_approval"

      assert {:ok, updated} = Policies.save_rules(rules("deny"), subject)
      assert updated.id == created.id
      assert updated.rules["defaults"]["high"] == "deny"
      assert updated.vsn > created.vsn
    end

    test "saving identical rules keeps the same row and version" do
      membership = Fixtures.Memberships.create_membership(role: "owner")
      subject = Fixtures.Subjects.membership_subject(membership)
      policy_rules = rules("require_approval")

      assert {:ok, created} = Policies.save_rules(policy_rules, subject)
      assert {:ok, unchanged} = Policies.save_rules(policy_rules, subject)

      assert unchanged.id == created.id
      assert unchanged.vsn == created.vsn
    end

    test "a viewer can't save policy rules" do
      {_owner, account, _owner_subject} = Fixtures.Subjects.owner_subject()
      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      viewer_subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      assert Policies.save_rules(rules("require_approval"), viewer_subject) ==
               {:error, :unauthorized}
    end
  end

  describe "evaluate_with_policy/3" do
    setup do
      account = Fixtures.Accounts.create_account()
      %{account: account}
    end

    test "an account with no policy default-denies every dispatch", %{account: account} do
      assert Policies.evaluate_with_policy(
               account.id,
               %{action_id: "linux.uptime", risk: :low},
               nil
             ) ==
               {:deny, [], "No policy is configured for this account, so this action was denied.",
                nil}
    end

    test "bridges the catalog's risk atom to the stored string tiers", %{account: account} do
      _ =
        Fixtures.Policies.create_policy(
          account_id: account.id,
          rules: %{
            "schema_version" => 2,
            "defaults" => %{
              "low" => "allow",
              "medium" => "allow",
              "high" => "require_approval",
              "critical" => "deny"
            },
            "overrides" => []
          }
        )

      {decision, _matched, _reason, %Policies.Policy{} = policy} =
        Policies.evaluate_with_policy(account.id, %{action_id: "db.drop", risk: :high}, nil)

      # The policy gates high-risk behind approval — the
      # :high ATOM (Ecto.Enum) must match the "high" string tier.
      assert decision == :require_approval
      assert policy.account_id == account.id
    end
  end
end
