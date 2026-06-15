defmodule Emisar.PoliciesPersistenceTest do
  @moduledoc """
  DB-backed coverage for the policy save surface (the pure evaluation
  logic lives in `Emisar.PoliciesTest`): `save_rules/2` both creates the
  account's first policy and updates an existing one, behind the
  manage_policies gate.
  """
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.Auth.Subject
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
               Policies.evaluate_with_policy(
                 account.id,
                 %{action_id: "linux.uptime", risk: :low},
                 nil
               )
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

  describe "predict_decisions/2" do
    test "matches the per-target verdict dispatch's policy would reach" do
      {_user, account, subject} = owner_subject_fixture()
      {:ok, _} = Policies.save_rules(rules("require_approval"), subject)
      runner = runner_fixture(account_id: account.id, group: "default")

      targets = [
        %{runner_id: runner.id, group: runner.group, action_id: "linux.uptime", risk: :low},
        %{runner_id: runner.id, group: runner.group, action_id: "linux.reboot", risk: :high},
        %{runner_id: runner.id, group: runner.group, action_id: "db.drop", risk: :critical}
      ]

      assert {:ok, decisions} = Policies.predict_decisions(targets, subject)

      # Same verdicts evaluate_with_policy gives: low allows, high needs
      # approval, critical denies — keyed by {runner_id, action_id}.
      assert decisions[{runner.id, "linux.uptime"}] == :allow
      assert decisions[{runner.id, "linux.reboot"}] == :require_approval
      assert decisions[{runner.id, "db.drop"}] == :deny
    end

    test "a runner-scoped override wins over the account default, like dispatch" do
      {_user, account, subject} = owner_subject_fixture()
      {:ok, _} = Policies.save_rules(rules("require_approval"), subject)
      runner = runner_fixture(account_id: account.id, group: "default")

      # Scope high → allow for THIS runner; the account default still gates high.
      {:ok, _} =
        Policies.save_scoped_rules(rules("allow"), :runner, runner.id, subject)

      targets = [
        %{runner_id: runner.id, group: runner.group, action_id: "linux.reboot", risk: :high}
      ]

      assert {:ok, decisions} = Policies.predict_decisions(targets, subject)
      assert decisions[{runner.id, "linux.reboot"}] == :allow
    end

    test "an api_client (no view_policies) is denied" do
      {_user, account, owner} = owner_subject_fixture()
      {:ok, _} = Policies.save_rules(rules("require_approval"), owner)
      runner = runner_fixture(account_id: account.id, group: "default")

      {_raw, api_key} = api_key_fixture(account_id: account.id)
      api_subject = Subject.for_api_key(api_key, account)

      targets = [
        %{runner_id: runner.id, group: runner.group, action_id: "linux.reboot", risk: :high}
      ]

      assert {:error, :unauthorized} = Policies.predict_decisions(targets, api_subject)
    end

    test "another account's subject sees ITS OWN policy verdict, never account A's" do
      # Account A blocks high outright; account B (its owner_subject_fixture
      # default) gates high behind approval. A B-subject reading a target that
      # names account A's runner must get B's verdict — proving the read scoped
      # to B's policy, not A's.
      {_user_a, account_a, subject_a} = owner_subject_fixture()
      {:ok, _} = Policies.save_rules(rules("deny"), subject_a)
      runner_a = runner_fixture(account_id: account_a.id, group: "default")

      {_user_b, _account_b, subject_b} = owner_subject_fixture()

      targets = [
        %{runner_id: runner_a.id, group: runner_a.group, action_id: "linux.reboot", risk: :high}
      ]

      assert {:ok, decisions} = Policies.predict_decisions(targets, subject_b)
      # B's default gates high → require_approval; if the read leaked A's policy
      # it would be :deny.
      assert decisions[{runner_a.id, "linux.reboot"}] == :require_approval
    end
  end
end
