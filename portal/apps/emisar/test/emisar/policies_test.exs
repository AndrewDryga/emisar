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

      assert reason =~ "Override:"

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

    test "overrides match action_id case-insensitively (a case slip can't dodge a deny)" do
      rules = %{
        "schema_version" => 2,
        "defaults" => %{"low" => "allow"},
        "overrides" => [
          %{"name" => "block-drops", "action" => "*.drop_*", "decision" => "deny"}
        ]
      }

      # The uppercased action id still trips the lowercase deny glob — were
      # the match case-sensitive it would fall through to the low-tier
      # default (allow), silently defeating the deny.
      assert {:deny, ["block-drops"], _} =
               Policies.evaluate(
                 %Policy{rules: rules},
                 %{"action_id" => "cassandra.DROP_table", "risk" => "low"},
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

    test "the evaluator ignores `kind` in match_ctx — action_id + risk decide" do
      # `kind` was dead plumbing in the evaluator: overrides match on the
      # action glob and defaults on the risk tier. Passing it (any value)
      # must not change the verdict.
      policy = %Policy{rules: Policies.default_rules()}

      base = %{"action_id" => "x", "risk" => "high"}

      assert Policies.evaluate(policy, base, %{}) ==
               Policies.evaluate(policy, Map.put(base, "kind", "exec"), %{})

      assert Policies.evaluate(policy, base, %{}) ==
               Policies.evaluate(policy, Map.put(base, "kind", "anything-else"), %{})
    end
  end

  describe "tier-monotonicity validation" do
    alias Emisar.Policies.Policy.Changeset, as: PolicyChangeset

    test "monotonic defaults pass validation" do
      rules = %{
        "schema_version" => 2,
        "defaults" => %{
          "low" => "allow",
          "medium" => "require_approval",
          "high" => "require_approval",
          "critical" => "deny"
        },
        "overrides" => []
      }

      changeset =
        PolicyChangeset.create(%{
          account_id: Ecto.UUID.generate(),
          rules: rules
        })

      assert changeset.valid?
    end

    test "rejects a higher tier that's more permissive than a lower tier" do
      rules = %{
        "schema_version" => 2,
        # medium=require_approval but high=allow → high is more
        # permissive than medium. Should be rejected.
        "defaults" => %{
          "low" => "allow",
          "medium" => "require_approval",
          "high" => "allow"
        },
        "overrides" => []
      }

      changeset =
        PolicyChangeset.create(%{
          account_id: Ecto.UUID.generate(),
          rules: rules
        })

      refute changeset.valid?

      assert {"higher-risk tiers must be at least as restrictive" <> _, []} =
               changeset.errors[:rules]
    end

    test "rejects critical=require_approval when high=deny" do
      rules = %{
        "schema_version" => 2,
        "defaults" => %{
          "low" => "allow",
          "medium" => "allow",
          "high" => "deny",
          "critical" => "require_approval"
        },
        "overrides" => []
      }

      changeset =
        PolicyChangeset.create(%{
          account_id: Ecto.UUID.generate(),
          rules: rules
        })

      refute changeset.valid?
    end

    test "Policies.decision_rank/1 orders allow < require_approval < deny" do
      assert Policies.decision_rank("allow") < Policies.decision_rank("require_approval")
      assert Policies.decision_rank("require_approval") < Policies.decision_rank("deny")
    end
  end

  describe "rules-shape validation (the policy-editor guardrails)" do
    defp rules_changeset(rules) do
      Policy.Changeset.create(%{account_id: Ecto.UUID.generate(), rules: rules})
    end

    test "rejects an unknown top-level rule section" do
      changeset = rules_changeset(%{"schema_version" => 2, "bogus_section" => %{}})
      refute changeset.valid?
      assert {"unknown rule sections:" <> _, _} = changeset.errors[:rules]
    end

    test "rejects an unknown risk tier in defaults" do
      changeset = rules_changeset(%{"defaults" => %{"extreme" => "deny"}})
      refute changeset.valid?
      assert {"unknown risk tiers:" <> _, _} = changeset.errors[:rules]
    end

    test "rejects an unknown decision value in defaults" do
      changeset = rules_changeset(%{"defaults" => %{"low" => "maybe"}})
      refute changeset.valid?
      assert {"unknown decisions:" <> _, _} = changeset.errors[:rules]
    end

    test "rejects defaults that isn't a JSON object" do
      changeset = rules_changeset(%{"defaults" => "allow-everything"})
      refute changeset.valid?
      assert {"defaults must be a JSON object", _} = changeset.errors[:rules]
    end

    test "rejects an override that isn't a JSON object" do
      changeset = rules_changeset(%{"overrides" => ["not-a-map"]})
      refute changeset.valid?
      assert {"each override must be a JSON object", _} = changeset.errors[:rules]
    end

    test "rejects overrides that isn't a list" do
      changeset = rules_changeset(%{"overrides" => %{"not" => "a list"}})
      refute changeset.valid?
      assert {"overrides must be a list", _} = changeset.errors[:rules]
    end

    test "a minimal policy with neither defaults nor overrides is valid" do
      assert rules_changeset(%{"schema_version" => 2}).valid?
    end

    test "rejects min_approvals: 0 in the approval section" do
      changeset = rules_changeset(%{"approval" => %{"min_approvals" => 0}})
      refute changeset.valid?
      assert {"min_approvals must be an integer >= 1", _} = changeset.errors[:rules]
    end

    test "rejects a non-boolean allow_self_approval" do
      changeset = rules_changeset(%{"approval" => %{"allow_self_approval" => "yes"}})
      refute changeset.valid?
      assert {"allow_self_approval must be a boolean", _} = changeset.errors[:rules]
    end

    test "rejects an unknown key inside the approval section" do
      changeset = rules_changeset(%{"approval" => %{"min_approvals" => 1, "bogus" => true}})
      refute changeset.valid?
      assert {"unknown approval keys:" <> _, _} = changeset.errors[:rules]
    end

    test "accepts a valid approval section" do
      changeset =
        rules_changeset(%{"approval" => %{"min_approvals" => 2, "allow_self_approval" => false}})

      assert changeset.valid?
    end

    test "a missing approval section is valid (back-compat with rules stored before the gate)" do
      assert rules_changeset(%{"schema_version" => 2, "defaults" => %{"low" => "allow"}}).valid?
    end

    test "updating with no rules change doesn't bump the version" do
      rules = %{"schema_version" => 2, "defaults" => %{"low" => "allow"}}
      policy = %Policy{vsn: 1, rules: rules}

      changeset = Policy.Changeset.update(policy, %{updated_by_id: Ecto.UUID.generate()})
      assert Ecto.Changeset.get_change(changeset, :vsn) == nil
    end
  end

  describe "catalogue accessors" do
    test "expose the tiers, decisions, and form changeset the editor renders" do
      assert Policies.risk_tiers() == ~w(low medium high critical)
      assert Policies.decisions() == ~w(allow require_approval deny)
      assert %Ecto.Changeset{} = Policies.change_policy()
    end
  end

  describe "approval-gate accessors" do
    test "min_approvals_for reads the section, floors at 1, tolerates a missing section" do
      assert Policies.min_approvals_for(%{"approval" => %{"min_approvals" => 3}}) == 3
      # Back-compat: rules stored before the section existed read as 1.
      assert Policies.min_approvals_for(%{"defaults" => %{}}) == 1
      assert Policies.min_approvals_for(%{}) == 1
      assert Policies.min_approvals_for(nil) == 1
      # Never below 1, even from a corrupt stored value.
      assert Policies.min_approvals_for(%{"approval" => %{"min_approvals" => 0}}) == 1
    end

    test "self_approval_allowed? defaults true, only an explicit false forbids" do
      assert Policies.self_approval_allowed?(%{"approval" => %{"allow_self_approval" => false}}) ==
               false

      assert Policies.self_approval_allowed?(%{"approval" => %{"allow_self_approval" => true}})
      assert Policies.self_approval_allowed?(%{"defaults" => %{}})
      assert Policies.self_approval_allowed?(%{})
      assert Policies.self_approval_allowed?(nil)
    end

    test "self_approval_allowed? fails CLOSED on a present non-boolean value" do
      # A corrupt / manually-written value must not silently widen the gate —
      # only a MISSING key keeps the legacy allow-default.
      for bad <- ["yes", "false", 0, 1, nil, %{}] do
        refute Policies.self_approval_allowed?(%{"approval" => %{"allow_self_approval" => bad}}),
               "expected #{inspect(bad)} to forbid self-approval"
      end

      # A non-map approval section doesn't raise and keeps the legacy default.
      assert Policies.self_approval_allowed?(%{"approval" => "garbage"})
    end

    test "the default rules reproduce single-approver, self-approval-allowed behavior" do
      assert Policies.min_approvals_for(Policies.default_rules()) == 1
      assert Policies.self_approval_allowed?(Policies.default_rules())
    end
  end

  describe "diff_rules/2" do
    test "reports only the tiers and overrides that actually moved" do
      before_rules = %{
        "schema_version" => 2,
        "defaults" => %{"low" => "allow", "high" => "require_approval"},
        "overrides" => [
          %{"name" => "keep", "action" => "a.*", "decision" => "allow"},
          %{"name" => "drop", "action" => "b.*", "decision" => "deny"},
          %{"name" => "flip", "action" => "c.*", "decision" => "allow"}
        ]
      }

      after_rules = %{
        "schema_version" => 2,
        "defaults" => %{"low" => "allow", "high" => "deny"},
        "overrides" => [
          %{"name" => "keep", "action" => "a.*", "decision" => "allow"},
          %{"name" => "flip", "action" => "c.*", "decision" => "deny"},
          %{"name" => "new", "action" => "d.*", "decision" => "deny"}
        ]
      }

      diff = Policies.diff_rules(before_rules, after_rules)

      assert diff["defaults"] == %{"high" => %{"from" => "require_approval", "to" => "deny"}}
      assert [%{"action" => "d.*"}] = diff["overrides"]["added"]
      assert [%{"action" => "b.*"}] = diff["overrides"]["removed"]
      assert [%{"action" => "c.*", "from" => _, "to" => _}] = diff["overrides"]["changed"]
    end
  end

  describe "shadowed_overrides/1" do
    test "a later deny shadowed by an earlier broader allow is dead" do
      rules = %{
        "overrides" => [
          %{"name" => "allow-nginx", "action" => "nginx_*", "decision" => "allow"},
          %{"name" => "block-reload", "action" => "nginx_reload", "decision" => "deny"}
        ]
      }

      assert Policies.shadowed_overrides(rules) == [%{index: 1, shadowed_by: 0}]
    end

    test "the reverse order is fine — the specific deny matches first" do
      rules = %{
        "overrides" => [
          %{"action" => "nginx_reload", "decision" => "deny"},
          %{"action" => "nginx_*", "decision" => "allow"}
        ]
      }

      assert Policies.shadowed_overrides(rules) == []
    end

    test "an identical-pattern duplicate is shadowed by the first" do
      rules = %{
        "overrides" => [
          %{"action" => "nginx_*", "decision" => "allow"},
          %{"action" => "nginx_*", "decision" => "deny"}
        ]
      }

      assert Policies.shadowed_overrides(rules) == [%{index: 1, shadowed_by: 0}]
    end

    test "disjoint globs never shadow each other" do
      rules = %{
        "overrides" => [
          %{"action" => "nginx_*", "decision" => "allow"},
          %{"action" => "apache_*", "decision" => "deny"}
        ]
      }

      assert Policies.shadowed_overrides(rules) == []
    end

    test "reports the FIRST subsumer when several earlier rows cover a row" do
      rules = %{
        "overrides" => [
          %{"action" => "*", "decision" => "allow"},
          %{"action" => "nginx_*", "decision" => "require_approval"},
          %{"action" => "nginx_reload", "decision" => "deny"}
        ]
      }

      assert Policies.shadowed_overrides(rules) == [
               %{index: 1, shadowed_by: 0},
               %{index: 2, shadowed_by: 0}
             ]
    end

    test "blank-action rows can't subsume or be subsumed — they're skipped" do
      rules = %{
        "overrides" => [
          %{"action" => "", "decision" => "allow"},
          %{"action" => "nginx_*", "decision" => "deny"}
        ]
      }

      assert Policies.shadowed_overrides(rules) == []
    end

    test "empty / missing overrides → []" do
      assert Policies.shadowed_overrides(%{"overrides" => []}) == []
      assert Policies.shadowed_overrides(%{}) == []
      assert Policies.shadowed_overrides(nil) == []
    end
  end
end
