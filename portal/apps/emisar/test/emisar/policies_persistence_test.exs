defmodule Emisar.PoliciesPersistenceTest do
  @moduledoc """
  DB-backed coverage for the policy save surface (the pure evaluation
  logic lives in `Emisar.PoliciesTest`): `save_rules/2` both creates the
  account's first policy and updates an existing one, behind the
  manage_policies gate.
  """
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

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
      "overrides" => []
    }
  end

  describe "save_rules/2" do
    test "creates the account's first policy, then updates it in place" do
      {_user, account, subject} = owner_subject_fixture()

      assert {:ok, created} = Policies.save_rules(rules("require_approval"), subject)
      assert created.account_id == account.id
      assert created.rules["defaults"]["high"] == "require_approval"

      assert {:ok, updated} = Policies.save_rules(rules("deny"), subject)
      assert updated.id == created.id
      assert updated.rules["defaults"]["high"] == "deny"
      assert updated.vsn > created.vsn
    end

    test "a viewer can't save policy rules" do
      {_owner, account, _owner_subject} = owner_subject_fixture()
      viewer = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: viewer.id, role: "viewer")
      viewer_subject = subject_for(viewer, account, role: :viewer)

      assert {:error, :unauthorized} =
               Policies.save_rules(rules("require_approval"), viewer_subject)
    end
  end

  describe "evaluate_with_policy/2" do
    test "an account with no policy default-denies every dispatch" do
      account = account_fixture()

      assert {:deny, [], "no policy configured for this account", nil} =
               Policies.evaluate_with_policy(account.id, %{action_id: "linux.uptime", risk: :low}, nil)
    end

    test "bridges the catalog's risk atom to the stored string tiers" do
      account = account_fixture()

      _ =
        policy_fixture(
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
