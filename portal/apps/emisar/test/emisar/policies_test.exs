defmodule Emisar.PoliciesTest do
  use ExUnit.Case, async: true

  alias Emisar.Policies
  alias Emisar.Policies.Policy

  describe "evaluate/3 — risk-tier defaults" do
    test "no policy means deny everything" do
      assert {:deny, [], reason} = Policies.evaluate(nil, %{"action_id" => "x.y"}, %{})
      assert reason =~ "no policy"
    end

    test "low/medium tier defaults to allow with stock defaults" do
      policy = %Policy{rules: Policies.default_rules()}

      assert {:allow, [], _} =
               Policies.evaluate(policy, %{"action_id" => "x", "risk" => "low"}, %{})

      assert {:allow, [], _} =
               Policies.evaluate(policy, %{"action_id" => "x", "risk" => "medium"}, %{})
    end

    test "high tier defaults to require_approval" do
      policy = %Policy{rules: Policies.default_rules()}

      assert {:require_approval, [], _} =
               Policies.evaluate(policy, %{"action_id" => "x", "risk" => "high"}, %{})
    end

    test "critical tier defaults to deny" do
      policy = %Policy{rules: Policies.default_rules()}

      assert {:deny, [], _} =
               Policies.evaluate(policy, %{"action_id" => "x", "risk" => "critical"}, %{})
    end

    test "operator can flip a single tier's default" do
      rules =
        Policies.default_rules()
        |> Map.update!("defaults", &Map.put(&1, "critical", "require_approval"))

      policy = %Policy{rules: rules}

      assert {:require_approval, [], _} =
               Policies.evaluate(policy, %{"action_id" => "x", "risk" => "critical"}, %{})
    end
  end

  describe "evaluate/3 — per-action overrides" do
    test "override beats tier default when action matches exactly" do
      rules = %{
        "schema_version" => 2,
        "defaults" => %{"low" => "allow"},
        "overrides" => [
          %{"name" => "block-bad", "action" => "x.bad", "decision" => "deny"}
        ]
      }

      assert {:deny, ["block-bad"], reason} =
               Policies.evaluate(
                 %Policy{rules: rules},
                 %{"action_id" => "x.bad", "risk" => "low"},
                 %{}
               )

      assert reason =~ "matched override"

      assert {:allow, [], _} =
               Policies.evaluate(
                 %Policy{rules: rules},
                 %{"action_id" => "x.fine", "risk" => "low"},
                 %{}
               )
    end

    test "glob overrides win when matched" do
      rules = %{
        "schema_version" => 2,
        "defaults" => %{"high" => "deny"},
        "overrides" => [
          %{
            "name" => "allow-cassandra-status",
            "action" => "cassandra.status_*",
            "decision" => "allow"
          }
        ]
      }

      assert {:allow, ["allow-cassandra-status"], _} =
               Policies.evaluate(
                 %Policy{rules: rules},
                 %{"action_id" => "cassandra.status_check", "risk" => "high"},
                 %{}
               )

      assert {:deny, [], _} =
               Policies.evaluate(
                 %Policy{rules: rules},
                 %{"action_id" => "cassandra.drop", "risk" => "high"},
                 %{}
               )
    end

    test "first matching override wins" do
      rules = %{
        "schema_version" => 2,
        "defaults" => %{"low" => "allow"},
        "overrides" => [
          %{"name" => "first", "action" => "linux.*", "decision" => "require_approval"},
          %{"name" => "second", "action" => "linux.uptime", "decision" => "deny"}
        ]
      }

      assert {:require_approval, ["first"], _} =
               Policies.evaluate(
                 %Policy{rules: rules},
                 %{"action_id" => "linux.uptime", "risk" => "low"},
                 %{}
               )
    end

    test "unknown tier falls back to deny" do
      rules = %{"schema_version" => 2, "defaults" => %{}, "overrides" => []}

      assert {:deny, [], _} =
               Policies.evaluate(
                 %Policy{rules: rules},
                 %{"action_id" => "x", "risk" => "low"},
                 %{}
               )
    end
  end
end
