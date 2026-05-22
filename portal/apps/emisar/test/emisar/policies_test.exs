defmodule Emisar.PoliciesTest do
  use ExUnit.Case, async: true

  alias Emisar.Policies
  alias Emisar.Policies.Policy

  describe "evaluate/3 — pure rule matching" do
    test "no policy means deny everything (default-deny)" do
      assert {:deny, [], reason} =
               Policies.evaluate(nil, %{"action_id" => "linux.uptime"}, %{})

      assert reason =~ "no policy"
    end

    test "allow rule matches by action glob" do
      policy = %Policy{rules: %{"allow" => [%{"name" => "linux-read", "action" => "linux.*"}]}}

      assert {:allow, ["linux-read"], _} =
               Policies.evaluate(policy, %{"action_id" => "linux.uptime"}, %{})
    end

    test "deny rule beats allow rule when both match" do
      policy = %Policy{
        rules: %{
          "deny" => [%{"name" => "no-cassandra-drop", "action" => "cassandra.drop_keyspace"}],
          "allow" => [%{"name" => "cassandra-all", "action" => "cassandra.*"}]
        }
      }

      assert {:deny, ["no-cassandra-drop"], reason} =
               Policies.evaluate(policy, %{"action_id" => "cassandra.drop_keyspace"}, %{})

      assert reason =~ "no-cassandra-drop"
    end

    test "require_approval beats allow when both match" do
      policy = %Policy{
        rules: %{
          "require_approval" => [%{"name" => "high-risk", "risk" => "high"}],
          "allow" => [%{"name" => "everything", "action" => "*"}]
        }
      }

      assert {:require_approval, ["high-risk"], _} =
               Policies.evaluate(policy, %{"action_id" => "x.y", "risk" => "high"}, %{})
    end

    test "max_risk lets low pass but not high" do
      policy = %Policy{
        rules: %{"allow" => [%{"name" => "low-only", "max_risk" => "medium"}]}
      }

      assert {:allow, _, _} =
               Policies.evaluate(policy, %{"action_id" => "x", "risk" => "low"}, %{})

      assert {:deny, [], _} =
               Policies.evaluate(policy, %{"action_id" => "x", "risk" => "high"}, %{})
    end

    test "arg conditions filter matches" do
      policy = %Policy{
        rules: %{
          "allow" => [
            %{
              "name" => "only-system-keyspace",
              "action" => "cassandra.repair",
              "args" => %{"keyspace" => %{"in" => ["system_auth", "system"]}}
            }
          ]
        }
      }

      assert {:allow, _, _} =
               Policies.evaluate(
                 policy,
                 %{"action_id" => "cassandra.repair"},
                 %{"keyspace" => "system_auth"}
               )

      assert {:deny, [], _} =
               Policies.evaluate(
                 policy,
                 %{"action_id" => "cassandra.repair"},
                 %{"keyspace" => "user_data"}
               )
    end

    test "no matching rule denies by default" do
      policy = %Policy{rules: %{"allow" => [%{"name" => "linux", "action" => "linux.*"}]}}

      assert {:deny, [], _} =
               Policies.evaluate(policy, %{"action_id" => "cassandra.status"}, %{})
    end
  end
end
