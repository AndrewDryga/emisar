defmodule Emisar.PoliciesTest do
  use Emisar.DataCase, async: true
  alias Emisar.Accounts
  alias Emisar.Accounts.RunnerAccess
  alias Emisar.Auth.Subject
  alias Emisar.Catalog
  alias Emisar.Fixtures
  alias Emisar.Policies
  alias Emisar.Policies.Policy
  alias Emisar.Runbooks.Compiler
  alias Emisar.Runners

  describe "default_rules/0" do
    test "reproduce single-approver, self-approval-allowed behavior" do
      assert {:ok, %{min_approvals: 1, allow_self_approval: true}} =
               Policies.approval_settings_for(Policies.default_rules())
    end

    test "carry a valid default decision for every risk tier" do
      defaults = Policies.default_rules()["defaults"]

      for tier <- Policies.risk_tiers() do
        assert defaults[tier] in Policies.decisions()
      end

      assert defaults["critical"] == "deny"
    end
  end

  describe "risk_tiers/0" do
    test "list the four tiers low→critical, the order the editor renders" do
      assert Policies.risk_tiers() == ~w(low medium high critical)
    end
  end

  describe "decisions/0" do
    test "list the three decisions in escalating order, matching decision_rank/1" do
      assert Policies.decisions() == ~w(allow require_approval deny)
      assert Enum.map(Policies.decisions(), &Policies.decision_rank/1) == [0, 1, 2]
    end
  end

  describe "max_min_approvals/0" do
    test "matches PostgreSQL's signed integer ceiling" do
      assert Policies.max_min_approvals() == 2_147_483_647
    end
  end

  describe "approval_settings_for/1" do
    test "returns a complete, typed gate" do
      assert {:ok, %{min_approvals: 3, allow_self_approval: false}} =
               Policies.approval_settings_for(%{
                 "approval" => %{"min_approvals" => 3, "allow_self_approval" => false}
               })
    end

    test "fails closed on missing, partial, extra, or malformed settings" do
      invalid = [
        nil,
        %{},
        %{"approval" => "garbage"},
        %{"approval" => %{"min_approvals" => 1}},
        %{"approval" => %{"allow_self_approval" => false}},
        %{"approval" => %{"min_approvals" => 0, "allow_self_approval" => false}},
        %{
          "approval" => %{
            "min_approvals" => Policies.max_min_approvals() + 1,
            "allow_self_approval" => false
          }
        },
        %{"approval" => %{"min_approvals" => 1, "allow_self_approval" => "yes"}},
        %{
          "approval" => %{
            "min_approvals" => 1,
            "allow_self_approval" => false,
            "unknown" => true
          }
        }
      ]

      for rules <- invalid do
        assert Policies.approval_settings_for(rules) == {:error, :invalid_policy_approval}
      end
    end
  end

  describe "decision_rank/1" do
    test "orders allow < require_approval < deny" do
      assert Policies.decision_rank("allow") == 0
      assert Policies.decision_rank("require_approval") == 1
      assert Policies.decision_rank("deny") == 2

      assert Policies.decision_rank("allow") < Policies.decision_rank("require_approval")
      assert Policies.decision_rank("require_approval") < Policies.decision_rank("deny")
    end

    test "an unknown decision ranks most-restrictive (fails closed)" do
      # Reachable only through malformed stored rules; a corrupt tier must read
      # as deny, never allow.
      assert Policies.decision_rank("maybe") == 2
      assert Policies.decision_rank(nil) == 2
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

  describe "unmatched_overrides/2" do
    @catalog %{"nginx.reload" => :medium, "nginx.error_tail" => :low, "linux.uptime" => :low}

    test "a glob that matches an action is not reported" do
      rules = %{"overrides" => [%{"action" => "nginx.*", "decision" => "deny"}]}

      assert Policies.unmatched_overrides(rules, @catalog) == []
    end

    test "a regex-flavored glob matches nothing and is reported" do
      # The grammar treats every character except `*` as a literal, so the
      # escaped dot can only match an action id containing a real backslash.
      # This reads as protection and denies nothing.
      rules = %{"overrides" => [%{"action" => "nginx\\.reload", "decision" => "deny"}]}

      assert Policies.unmatched_overrides(rules, @catalog) == [%{index: 0}]
    end

    test "reports every unmatched row in order and leaves matching rows alone" do
      rules = %{
        "overrides" => [
          %{"action" => "cassandra.*", "decision" => "deny"},
          %{"action" => "linux.uptime", "decision" => "allow"},
          %{"action" => "postgres.*", "decision" => "deny"}
        ]
      }

      assert Policies.unmatched_overrides(rules, @catalog) == [%{index: 0}, %{index: 2}]
    end

    test "matching stays case-insensitive, exactly as dispatch matches" do
      rules = %{"overrides" => [%{"action" => "NGINX.RELOAD", "decision" => "deny"}]}

      assert Policies.unmatched_overrides(rules, @catalog) == []
    end

    test "a blank row is the editor's half-filled state and owns its own error" do
      rules = %{"overrides" => [%{"action" => "", "decision" => "deny"}]}

      assert Policies.unmatched_overrides(rules, @catalog) == []
    end

    test "an empty catalog reports nothing — everything would look unmatched" do
      rules = %{"overrides" => [%{"action" => "cassandra.*", "decision" => "deny"}]}

      assert Policies.unmatched_overrides(rules, %{}) == []
    end

    test "empty / missing overrides → []" do
      assert Policies.unmatched_overrides(%{"overrides" => []}, @catalog) == []
      assert Policies.unmatched_overrides(%{}, @catalog) == []
      assert Policies.unmatched_overrides(nil, @catalog) == []
    end
  end

  describe "editor_input/1" do
    test "the default rules become a complete, valid editor input" do
      assert Policies.editor_input(Policies.default_rules()) == %{
               defaults: %{
                 "low" => "allow",
                 "medium" => "allow",
                 "high" => "require_approval",
                 "critical" => "deny"
               },
               overrides: [],
               approval: %{"min_approvals" => 1, "allow_self_approval" => true},
               approval_valid?: true
             }
    end

    test "keeps stored values that are already valid" do
      defaults = %{
        "low" => "allow",
        "medium" => "require_approval",
        "high" => "deny",
        "critical" => "deny"
      }

      overrides = [%{"name" => "block-drop", "action" => "*.drop_*", "decision" => "deny"}]
      approval = %{"min_approvals" => 3, "allow_self_approval" => false}

      rules = %{
        "schema_version" => 2,
        "defaults" => defaults,
        "overrides" => overrides,
        "approval" => approval
      }

      assert Policies.editor_input(rules) == %{
               defaults: defaults,
               overrides: overrides,
               approval: approval,
               approval_valid?: true
             }
    end

    test "a missing or unknown tier decision repairs to deny, never allow" do
      input =
        Policies.editor_input(%{"defaults" => %{"low" => "allow", "medium" => "obliterate"}})

      assert input.defaults == %{
               "low" => "allow",
               "medium" => "deny",
               "high" => "deny",
               "critical" => "deny"
             }
    end

    test "non-monotonic stored defaults lift higher tiers without widening access" do
      input =
        Policies.editor_input(%{
          "defaults" => %{
            "low" => "require_approval",
            "medium" => "allow",
            "high" => "deny",
            "critical" => "require_approval"
          }
        })

      assert input.defaults == %{
               "low" => "require_approval",
               "medium" => "require_approval",
               "high" => "deny",
               "critical" => "deny"
             }

      changeset = input |> Policies.build_rules() |> Policies.change_policy()
      assert changeset.valid?
    end

    test "non-map defaults and non-list overrides deny every tier and drop every row" do
      deny_all = %{"low" => "deny", "medium" => "deny", "high" => "deny", "critical" => "deny"}

      for rules <- [%{"defaults" => "junk", "overrides" => "junk"}, %{}, nil, "junk", []] do
        input = Policies.editor_input(rules)

        assert input.defaults == deny_all
        assert input.overrides == []
      end
    end

    test "an unknown override decision repairs to deny and non-string fields to blanks" do
      overrides = [
        %{"name" => "keep", "action" => "nginx_*", "decision" => "obliterate"},
        %{"name" => 42, "action" => nil, "decision" => "allow"},
        "not-an-object"
      ]

      assert Policies.editor_input(%{"overrides" => overrides}).overrides == [
               %{"name" => "keep", "action" => "nginx_*", "decision" => "deny"},
               %{"name" => "", "action" => "", "decision" => "allow"},
               %{"name" => "", "action" => "", "decision" => "deny"}
             ]
    end

    test "a padded stored override is trimmed and forced to deny" do
      rules = %{
        "overrides" => [
          %{"name" => "reads", "action" => "  linux.*  ", "decision" => "allow"}
        ]
      }

      assert Policies.editor_input(rules).overrides == [
               %{"name" => "reads", "action" => "linux.*", "decision" => "deny"}
             ]
    end

    test "an unusable approval gate repairs to one non-self approver and reports it" do
      invalid = [
        %{},
        %{"approval" => "garbage"},
        %{"approval" => %{"min_approvals" => 0, "allow_self_approval" => false}},
        %{"approval" => %{"min_approvals" => 1, "allow_self_approval" => "yes"}}
      ]

      for rules <- invalid do
        input = Policies.editor_input(rules)

        assert input.approval == %{"min_approvals" => 1, "allow_self_approval" => false}
        refute input.approval_valid?
      end
    end

    test "a repaired input builds rules the changeset accepts" do
      input = Policies.editor_input(%{"defaults" => "junk", "overrides" => ["junk"]})
      changeset = input |> Policies.build_rules() |> Policies.change_policy()

      assert changeset.valid?
    end
  end

  describe "update_editor_input/2" do
    setup do
      %{input: Policies.editor_input(Policies.default_rules())}
    end

    test "changes that omit a section leave the input untouched", %{input: input} do
      assert Policies.update_editor_input(input, %{}) == input
    end

    test "an unknown posted decision keeps the current value", %{input: input} do
      updated = Policies.update_editor_input(input, %{defaults: %{"high" => "obliterate"}})

      assert updated.defaults == input.defaults
    end

    test "low=deny lifts every later tier to deny" do
      input = Policies.editor_input(Policies.default_rules())
      updated = Policies.update_editor_input(input, %{defaults: %{"low" => "deny"}})

      assert updated.defaults == %{
               "low" => "deny",
               "medium" => "deny",
               "high" => "deny",
               "critical" => "deny"
             }
    end

    test "a tier posted more permissive than a lower one is lifted to it", %{input: input} do
      changes = %{defaults: %{"low" => "require_approval", "high" => "allow"}}
      updated = Policies.update_editor_input(input, changes)

      assert updated.defaults == %{
               "low" => "require_approval",
               "medium" => "require_approval",
               "high" => "require_approval",
               "critical" => "deny"
             }
    end

    test "override edits retain current fields when posted values are invalid", %{input: input} do
      current = %{
        input
        | overrides: [%{"name" => "keep", "action" => "nginx_*", "decision" => "allow"}]
      }

      posted = %{"name" => 42, "action" => "nginx_reload", "decision" => "obliterate"}
      updated = Policies.update_editor_input(current, %{overrides: [posted]})

      assert updated.overrides == [
               %{"name" => "keep", "action" => "nginx_reload", "decision" => "allow"}
             ]
    end

    test "a posted row past the server-owned overrides is ignored", %{input: input} do
      current = %{input | overrides: [Policies.empty_override()]}

      posted = [
        %{"name" => "mine", "action" => "nginx_*", "decision" => "allow"},
        %{"name" => "appended", "action" => "*", "decision" => "allow"}
      ]

      updated = Policies.update_editor_input(current, %{overrides: posted})

      assert updated.overrides == [
               %{"name" => "mine", "action" => "nginx_*", "decision" => "allow"}
             ]
    end

    test "an explicit approval replaces the gate while approval_valid? rides through" do
      input = Policies.editor_input(%{})
      approval = %{"min_approvals" => 2, "allow_self_approval" => false}
      updated = Policies.update_editor_input(input, %{approval: approval})

      assert updated.approval == approval
      refute updated.approval_valid?
    end

    test "an incomplete or malformed approval change keeps the complete current gate", %{
      input: input
    } do
      invalid = [
        %{},
        %{"min_approvals" => 0, "allow_self_approval" => false},
        %{"min_approvals" => 2, "allow_self_approval" => "false"}
      ]

      for approval <- invalid do
        updated = Policies.update_editor_input(input, %{approval: approval})
        assert updated.approval == input.approval
      end
    end

    test "the updated input builds rules the changeset accepts", %{input: input} do
      updated = Policies.update_editor_input(input, %{defaults: %{"low" => "require_approval"}})
      changeset = updated |> Policies.build_rules() |> Policies.change_policy()

      assert changeset.valid?
    end
  end

  describe "empty_override/0" do
    test "an intentional new row starts at allow, unlike a repaired stored one" do
      assert Policies.empty_override() == %{"name" => "", "action" => "", "decision" => "allow"}
    end
  end

  describe "build_rules/1" do
    setup do
      %{input: Policies.editor_input(Policies.default_rules())}
    end

    test "round-trips the default rules through the editor unchanged", %{input: input} do
      assert Policies.build_rules(input) == Policies.default_rules()
    end

    test "trims override names and actions, preserving their order", %{input: input} do
      overrides = [
        %{"name" => "  first  ", "action" => "  nginx_*  ", "decision" => "deny"},
        %{"name" => "", "action" => "apache_*", "decision" => "allow"}
      ]

      rules = Policies.build_rules(%{input | overrides: overrides})

      assert rules["overrides"] == [
               %{"name" => "first", "action" => "nginx_*", "decision" => "deny"},
               %{"name" => "", "action" => "apache_*", "decision" => "allow"}
             ]
    end

    test "drops blank-action rows, so an untouched new row saves cleanly", %{input: input} do
      overrides = [
        Policies.empty_override(),
        %{"name" => "kept", "action" => "nginx_*", "decision" => "deny"},
        %{"name" => "half-typed", "action" => "   ", "decision" => "deny"}
      ]

      rules = Policies.build_rules(%{input | overrides: overrides})
      changeset = Policies.change_policy(rules)

      assert rules["overrides"] == [
               %{"name" => "kept", "action" => "nginx_*", "decision" => "deny"}
             ]

      assert changeset.valid?
    end

    test "copies the typed approval gate unchanged", %{input: input} do
      approval = %{"min_approvals" => 4, "allow_self_approval" => false}

      assert Policies.build_rules(%{input | approval: approval})["approval"] == approval
    end

    test "hardcodes schema version 2 whatever the input came from", %{input: input} do
      assert Policies.build_rules(input)["schema_version"] == 2
      assert Policies.build_rules(Policies.editor_input(%{}))["schema_version"] == 2
    end
  end

  describe "change_policy/1" do
    test "with no argument builds a form changeset off the default rules" do
      changeset = Policies.change_policy()
      assert %Ecto.Changeset{} = changeset
      assert changeset.valid?
    end

    test "validates a supplied rules map so the editor can render the error inline" do
      # A bogus top-level section makes the form changeset invalid with the
      # rules-level error the LiveView surfaces.
      changeset = Policies.change_policy(%{"schema_version" => 2, "bogus_section" => %{}})
      refute changeset.valid?
      assert ["unknown rule sections:" <> _] = errors_on(changeset).rules
    end
  end

  # change_policy/0 builds the form changeset; these guard the rules-level
  # validation it (and the persisted save) rely on — monotonic tiers and the
  # editor's shape guardrails.
  describe "change_policy/1 — tier-monotonicity validation" do
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
        "overrides" => [],
        "approval" => %{"min_approvals" => 1, "allow_self_approval" => true}
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
        "overrides" => [],
        "approval" => %{"min_approvals" => 1, "allow_self_approval" => true}
      }

      changeset =
        PolicyChangeset.create(%{
          account_id: Ecto.UUID.generate(),
          rules: rules
        })

      refute changeset.valid?

      assert ["higher-risk tiers must be at least as restrictive" <> _] =
               errors_on(changeset).rules
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
        "overrides" => [],
        "approval" => %{"min_approvals" => 1, "allow_self_approval" => true}
      }

      changeset =
        PolicyChangeset.create(%{
          account_id: Ecto.UUID.generate(),
          rules: rules
        })

      refute changeset.valid?
    end
  end

  describe "change_policy/1 — rules-shape validation (the policy-editor guardrails)" do
    defp rules_changeset(rules) do
      rules =
        Map.put_new(rules, "approval", %{"min_approvals" => 1, "allow_self_approval" => true})

      Policy.Changeset.create(%{account_id: Ecto.UUID.generate(), rules: rules})
    end

    test "rejects an unknown top-level rule section" do
      changeset = rules_changeset(%{"schema_version" => 2, "bogus_section" => %{}})
      refute changeset.valid?
      assert ["unknown rule sections:" <> _] = errors_on(changeset).rules
    end

    test "rejects an unknown risk tier in defaults" do
      changeset = rules_changeset(%{"defaults" => %{"extreme" => "deny"}})
      refute changeset.valid?
      assert ["unknown risk tiers:" <> _] = errors_on(changeset).rules
    end

    test "rejects an unknown decision value in defaults" do
      changeset = rules_changeset(%{"defaults" => %{"low" => "maybe"}})
      refute changeset.valid?
      assert ["unknown decisions:" <> _] = errors_on(changeset).rules
    end

    test "rejects defaults that isn't a JSON object" do
      changeset = rules_changeset(%{"defaults" => "allow-everything"})
      refute changeset.valid?
      assert errors_on(changeset).rules == ["defaults must be a JSON object"]
    end

    test "rejects an override that isn't a JSON object" do
      changeset = rules_changeset(%{"overrides" => ["not-a-map"]})
      refute changeset.valid?
      assert errors_on(changeset).rules == ["each override must be a JSON object"]
    end

    test "rejects overrides that isn't a list" do
      changeset = rules_changeset(%{"overrides" => %{"not" => "a list"}})
      refute changeset.valid?
      assert errors_on(changeset).rules == ["overrides must be a list"]
    end

    test "rejects an override without an action" do
      for action <- [nil, "", "   ", 42] do
        changeset =
          rules_changeset(%{"overrides" => [%{"action" => action, "decision" => "deny"}]})

        refute changeset.valid?
        assert errors_on(changeset).rules == ["override action is required"]
      end
    end

    test "rejects an override action with surrounding whitespace" do
      changeset =
        rules_changeset(%{
          "overrides" => [%{"action" => " linux.* ", "decision" => "allow"}]
        })

      refute changeset.valid?

      assert errors_on(changeset).rules == [
               "override action must not have surrounding whitespace"
             ]
    end

    test "a minimal policy with neither defaults nor overrides is valid" do
      assert rules_changeset(%{"schema_version" => 2}).valid?
    end

    test "rejects min_approvals: 0 in the approval section" do
      changeset =
        rules_changeset(%{
          "approval" => %{"min_approvals" => 0, "allow_self_approval" => true}
        })

      refute changeset.valid?

      assert ["min_approvals must be an integer between 1 and " <> _] =
               errors_on(changeset).rules
    end

    test "rejects a non-boolean allow_self_approval" do
      changeset =
        rules_changeset(%{
          "approval" => %{"min_approvals" => 1, "allow_self_approval" => "yes"}
        })

      refute changeset.valid?
      assert errors_on(changeset).rules == ["allow_self_approval must be a boolean"]
    end

    test "rejects an unknown key inside the approval section" do
      changeset =
        rules_changeset(%{
          "approval" => %{
            "min_approvals" => 1,
            "allow_self_approval" => true,
            "bogus" => true
          }
        })

      refute changeset.valid?
      assert ["unknown approval keys:" <> _] = errors_on(changeset).rules
    end

    test "accepts a valid approval section" do
      changeset =
        rules_changeset(%{"approval" => %{"min_approvals" => 2, "allow_self_approval" => false}})

      assert changeset.valid?
    end

    test "rejects either missing approval setting" do
      missing_min = rules_changeset(%{"approval" => %{"allow_self_approval" => false}})
      refute missing_min.valid?
      assert errors_on(missing_min).rules == ["min_approvals is required"]

      missing_self = rules_changeset(%{"approval" => %{"min_approvals" => 1}})
      refute missing_self.valid?
      assert errors_on(missing_self).rules == ["allow_self_approval is required"]
    end

    test "rejects a missing approval section after the backfill" do
      changeset =
        Policy.Changeset.create(%{
          account_id: Ecto.UUID.generate(),
          rules: %{"schema_version" => 2, "defaults" => %{"low" => "allow"}}
        })

      refute changeset.valid?
      assert errors_on(changeset).rules == ["approval settings are required"]
    end
  end

  describe "fetch_policy/1" do
    test "returns the account's default policy for a member subject" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()

      assert {:ok, %Policy{} = policy} = Policies.fetch_policy(subject)
      assert policy.account_id == account.id
      assert policy.scope_type == :account
    end

    test "an operator (view_policies) can read it; an api_client cannot" do
      {_owner, account, _owner_subject} = Fixtures.Subjects.owner_subject()

      operator =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :operator)

      assert {:ok, %Policy{}} = Policies.fetch_policy(operator)

      {_raw, api_key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)
      api_subject = Subject.for_api_key(api_key, account)

      assert Policies.fetch_policy(api_subject) == {:error, :unauthorized}
    end

    test "cross-account: a subject only ever reads its OWN account's policy" do
      {_user_a, account_a, subject_a} = Fixtures.Subjects.owner_subject()
      {_user_b, account_b, subject_b} = Fixtures.Subjects.owner_subject()

      {:ok, policy_a} = Policies.fetch_policy(subject_a)
      {:ok, policy_b} = Policies.fetch_policy(subject_b)

      assert policy_a.account_id == account_a.id
      assert policy_b.account_id == account_b.id
      refute policy_a.id == policy_b.id
    end
  end

  describe "snapshot_runbook_decisions/2" do
    test "returns the account default's decision, reason, and approval settings" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = trusted_runner(account, subject, "database")

      assert {:ok, compiled} = compile_uptime_plan(subject, runner.group)
      assert [snapshot] = Policies.snapshot_runbook_decisions(account.id, compiled.items)

      assert snapshot.decision == :allow
      assert snapshot.policy.scope_type == :account
      assert snapshot.policy.account_id == account.id
      assert snapshot.approval == nil
      assert is_binary(snapshot.reason)
    end

    test "resolves the ruleset targeting the compiled item's runner group" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = trusted_runner(account, subject, "database")
      rules = require_approval_rules(min_approvals: 2, allow_self_approval: false)

      {:ok, group_policy} = Policies.save_scoped_rules(rules, :group, runner.group, subject)

      assert {:ok, compiled} = compile_uptime_plan(subject, runner.group)
      assert [snapshot] = Policies.snapshot_runbook_decisions(account.id, compiled.items)

      assert snapshot.decision == :require_approval
      assert snapshot.policy.id == group_policy.id
      assert snapshot.approval == %{min_approvals: 2, allow_self_approval: false}
    end
  end

  describe "list_scoped_policies/1" do
    test "lists the account's scoped overrides, excluding the account default" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      {:ok, scoped} = Policies.save_scoped_rules(allow_all_rules(), :runner, runner.id, subject)

      assert {:ok, [listed]} = Policies.list_scoped_policies(subject)
      assert listed.id == scoped.id
      # The account default isn't a scoped override, so it never lists here.
      refute listed.scope_type == :account
    end

    test "an operator (view_policies) can list; an api_client cannot" do
      {_owner, account, owner} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      {:ok, _} = Policies.save_scoped_rules(allow_all_rules(), :runner, runner.id, owner)

      operator_membership =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")

      operator = Fixtures.Subjects.membership_subject(operator_membership)

      assert {:ok, [_]} = Policies.list_scoped_policies(operator)

      {_raw, api_key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)
      api_subject = Subject.for_api_key(api_key, account)
      assert Policies.list_scoped_policies(api_subject) == {:error, :unauthorized}
    end

    test "cross-account: never lists another account's overrides" do
      {_user_a, account_a, subject_a} = Fixtures.Subjects.owner_subject()
      runner_a = Fixtures.Runners.create_runner(account_id: account_a.id, connected?: false)
      {:ok, _} = Policies.save_scoped_rules(allow_all_rules(), :runner, runner_a.id, subject_a)

      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()
      assert Policies.list_scoped_policies(subject_b) == {:ok, []}
    end

    # A ruleset names its target and spells out what may run there, so the list
    # is the fleet — plus its rules — by another name.
    test "a restricted member reads only the rulesets whose target they reach" do
      {_owner, account, owner} = Fixtures.Subjects.owner_subject()
      db = Fixtures.Runners.create_runner(account_id: account.id, group: "db", connected?: false)

      Fixtures.Runners.create_runner(account_id: account.id, group: "edge", connected?: false)

      {:ok, db_policy} = Policies.save_scoped_rules(allow_all_rules(), :runner, db.id, owner)
      {:ok, _edge_policy} = Policies.save_scoped_rules(deny_all_rules(), :group, "edge", owner)

      member = restricted_member(account, owner, "operator", ["db"])

      assert {:ok, [listed]} = Policies.list_scoped_policies(member)
      assert listed.id == db_policy.id
    end

    test "a member with no runner access reads no rulesets" do
      {_owner, account, owner} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      {:ok, _} = Policies.save_scoped_rules(allow_all_rules(), :runner, runner.id, owner)

      member_membership =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")

      member = Fixtures.Subjects.membership_subject(member_membership)

      {:ok, _updated} =
        Accounts.update_membership_runner_access(member_membership, RunnerAccess.none(), owner)

      assert Policies.list_scoped_policies(member) == {:ok, []}
    end

    # Group names are not account-unique, and the narrowing matches on the name.
    test "cross-account: a group name shared with another account lists nothing of theirs" do
      {_owner_a, account_a, owner_a} = Fixtures.Subjects.owner_subject()
      Fixtures.Runners.create_runner(account_id: account_a.id, group: "db", connected?: false)

      {_owner_b, account_b, owner_b} = Fixtures.Subjects.owner_subject()
      Fixtures.Runners.create_runner(account_id: account_b.id, group: "db", connected?: false)
      {:ok, _policy_b} = Policies.save_scoped_rules(deny_all_rules(), :group, "db", owner_b)

      member_a = restricted_member(account_a, owner_a, "operator", ["db"])

      assert Policies.list_scoped_policies(member_a) == {:ok, []}
    end
  end

  describe "delete_scoped_policy/2" do
    test "soft-deletes an override so its scope falls back to the next-broader scope" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      {:ok, policy} = Policies.save_scoped_rules(deny_all_rules(), :runner, runner.id, subject)

      assert {:ok, deleted} = Policies.delete_scoped_policy(policy, subject)
      assert deleted.id == policy.id
      refute is_nil(deleted.deleted_at)

      # Gone from the editor's list; the scope now resolves to the broader default.
      assert Policies.list_scoped_policies(subject) == {:ok, []}
    end

    test "a viewer can't delete an override (no manage_policies)" do
      {_owner, account, owner} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      {:ok, policy} = Policies.save_scoped_rules(deny_all_rules(), :runner, runner.id, owner)

      viewer =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :viewer)

      assert Policies.delete_scoped_policy(policy, viewer) == {:error, :unauthorized}
      # The row is untouched — still live.
      assert {:ok, [_]} = Policies.list_scoped_policies(owner)
    end

    # Removing a ruleset changes what may run on its hosts, so the scope is
    # re-judged at the mutation boundary — a page held open across an access
    # change cannot spend the row it is still showing.
    test "a restricted admin can't delete a ruleset outside their fleet" do
      {_owner, account, owner} = Fixtures.Subjects.owner_subject()
      Fixtures.Runners.create_runner(account_id: account.id, group: "db", connected?: false)

      edge =
        Fixtures.Runners.create_runner(account_id: account.id, group: "edge", connected?: false)

      {:ok, policy} = Policies.save_scoped_rules(deny_all_rules(), :runner, edge.id, owner)

      admin = restricted_member(account, owner, "admin", ["db"])

      assert Policies.delete_scoped_policy(policy, admin) == {:error, :runner_not_found}
      assert {:ok, [_still_live]} = Policies.list_scoped_policies(owner)
    end

    test "cross-account: B can't delete A's override (:not_found, row untouched)" do
      {_user_a, account_a, subject_a} = Fixtures.Subjects.owner_subject()
      runner_a = Fixtures.Runners.create_runner(account_id: account_a.id, connected?: false)

      {:ok, policy_a} =
        Policies.save_scoped_rules(deny_all_rules(), :runner, runner_a.id, subject_a)

      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      # delete_scoped_policy guards with Subject.ensure_in_account (default
      # :not_found), so B is refused without A's override being touched.
      assert Policies.delete_scoped_policy(policy_a, subject_b) == {:error, :not_found}
      assert {:ok, [_]} = Policies.list_scoped_policies(subject_a)
    end
  end

  describe "save_scoped_rules/4" do
    test "creates a runner override, then upserts the same row in place" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

      assert {:ok, created} =
               Policies.save_scoped_rules(deny_all_rules(), :runner, runner.id, subject)

      assert created.account_id == account.id
      assert created.scope_type == :runner
      assert created.scope_value == runner.id
      assert created.rules["defaults"]["low"] == "deny"

      # A second save of the same scope is an upsert: same row, bumped vsn.
      assert {:ok, updated} =
               Policies.save_scoped_rules(allow_all_rules(), :runner, runner.id, subject)

      assert updated.id == created.id
      assert updated.vsn == created.vsn + 1
      assert updated.rules["defaults"]["low"] == "allow"
    end

    test "rejects a blank scope_value for a runner/group scope" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()

      assert Policies.save_scoped_rules(deny_all_rules(), :runner, "", subject) ==
               {:error, :runner_not_found}

      assert Policies.save_scoped_rules(deny_all_rules(), :group, "", subject) ==
               {:error, :group_not_found}
    end

    test "rejects another account's runner id (:runner_not_found, no row written)" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      foreign_runner = Fixtures.Runners.create_runner(connected?: false)

      assert Policies.save_scoped_rules(deny_all_rules(), :runner, foreign_runner.id, subject) ==
               {:error, :runner_not_found}

      assert Policies.list_scoped_policies(subject) == {:ok, []}
    end

    test "rejects a nonexistent and a malformed runner id (:runner_not_found)" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()

      assert Policies.save_scoped_rules(
               deny_all_rules(),
               :runner,
               Ecto.UUID.generate(),
               subject
             ) == {:error, :runner_not_found}

      assert Policies.save_scoped_rules(deny_all_rules(), :runner, "not-a-uuid", subject) ==
               {:error, :runner_not_found}
    end

    test "rejects a soft-deleted runner's id (:runner_not_found)" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      {:ok, _} = Runners.delete_runner(runner, subject)

      assert Policies.save_scoped_rules(deny_all_rules(), :runner, runner.id, subject) ==
               {:error, :runner_not_found}
    end

    # Preparing the ruleset before enrolling the hosts is a real setup flow, and
    # an unrestricted writer can already see every group, so the name they invent
    # tells them nothing they did not already have.
    test "an unrestricted member may write a group ruleset before any runner is enrolled" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()

      assert {:ok, saved} =
               Policies.save_scoped_rules(deny_all_rules(), :group, "not-enrolled-yet", subject)

      assert saved.scope_value == "not-enrolled-yet"

      # The read side has to agree, or they would write a ruleset they cannot see.
      assert {:ok, [listed]} = Policies.list_scoped_policies(subject)
      assert listed.id == saved.id
      assert listed.scope_value == "not-enrolled-yet"
    end

    # Writing a ruleset for a host you cannot see is a policy change on somebody
    # else's fleet — and an existence answer alone would enumerate group names.
    test "a restricted admin can't write a ruleset outside their fleet" do
      {_owner, account, owner} = Fixtures.Subjects.owner_subject()
      Fixtures.Runners.create_runner(account_id: account.id, group: "db", connected?: false)

      edge =
        Fixtures.Runners.create_runner(account_id: account.id, group: "edge", connected?: false)

      admin = restricted_member(account, owner, "admin", ["db"])

      assert Policies.save_scoped_rules(deny_all_rules(), :runner, edge.id, admin) ==
               {:error, :runner_not_found}

      assert Policies.save_scoped_rules(deny_all_rules(), :group, "edge", admin) ==
               {:error, :group_not_found}

      # A group nobody has enrolled answers exactly as an out-of-reach one does,
      # so the save can never be used to enumerate group names.
      assert Policies.save_scoped_rules(deny_all_rules(), :group, "no-such-group", admin) ==
               {:error, :group_not_found}

      assert Policies.list_scoped_policies(owner) == {:ok, []}
    end

    test "a viewer can't save a scoped override (no manage_policies)" do
      {_owner, account, _owner_subject} = Fixtures.Subjects.owner_subject()

      viewer =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :viewer)

      assert Policies.save_scoped_rules(deny_all_rules(), :runner, "r1", viewer) ==
               {:error, :unauthorized}
    end

    test "cross-account: B can't claim A's runner id, and A's override is untouched" do
      {_user_a, account_a, subject_a} = Fixtures.Subjects.owner_subject()
      runner_a = Fixtures.Runners.create_runner(account_id: account_a.id, connected?: false)

      {:ok, policy_a} =
        Policies.save_scoped_rules(deny_all_rules(), :runner, runner_a.id, subject_a)

      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      assert Policies.save_scoped_rules(allow_all_rules(), :runner, runner_a.id, subject_b) ==
               {:error, :runner_not_found}

      assert Policies.list_scoped_policies(subject_b) == {:ok, []}

      assert {:ok, [fetched_a]} = Policies.list_scoped_policies(subject_a)
      assert fetched_a.id == policy_a.id
      assert fetched_a.rules["defaults"]["low"] == "deny"
      assert fetched_a.vsn == policy_a.vsn
    end
  end

  describe "policy mutation reach" do
    test "a runner-restricted admin cannot change the default but can manage an in-scope ruleset" do
      {_owner, account, owner} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "db")
      membership = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
      admin = Fixtures.Subjects.membership_subject(membership)
      default_before = Policies.peek_policy_for_account(account.id)
      {:ok, restricted} = RunnerAccess.restricted(["db"], [])

      {:ok, _updated} =
        Accounts.update_membership_runner_access(membership, restricted, owner)

      # The Subject was built before the access change. The mutation must read
      # the membership again instead of trusting the stale session snapshot.
      assert Policies.save_rules(deny_all_rules(), admin) == {:error, :unauthorized}

      default_after = Policies.peek_policy_for_account(account.id)
      assert default_after.rules == default_before.rules
      assert default_after.vsn == default_before.vsn

      assert {:ok, scoped} =
               Policies.save_scoped_rules(deny_all_rules(), :runner, runner.id, admin)

      assert scoped.scope_value == runner.id
    end

    test "a pack-restricted admin cannot save or delete any policy" do
      {_owner, account, owner} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "db")
      {:ok, scoped} = Policies.save_scoped_rules(deny_all_rules(), :runner, runner.id, owner)
      membership = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
      admin = Fixtures.Subjects.membership_subject(membership)
      default_before = Policies.peek_policy_for_account(account.id)
      {:ok, restricted} = RunnerAccess.new(:all, [], [], :restricted, ["postgres"])

      {:ok, _updated} =
        Accounts.update_membership_runner_access(membership, restricted, owner)

      assert Policies.save_rules(allow_all_rules(), admin) == {:error, :unauthorized}

      assert Policies.save_scoped_rules(allow_all_rules(), :runner, runner.id, admin) ==
               {:error, :unauthorized}

      assert Policies.delete_scoped_policy(scoped, admin) == {:error, :unauthorized}

      default_after = Policies.peek_policy_for_account(account.id)
      assert default_after.rules == default_before.rules
      assert default_after.vsn == default_before.vsn

      assert {:ok, [still_live]} = Policies.list_scoped_policies(owner)
      assert still_live.id == scoped.id
      assert still_live.rules == scoped.rules
    end
  end

  describe "subject_can_view_policies?/1" do
    test "true for a viewer, false for a billing_manager (the nav gate)" do
      account = Fixtures.Accounts.create_account()

      viewer_subject =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :viewer)

      billing_manager_subject =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account,
          role: :billing_manager
        )

      assert Policies.subject_can_view_policies?(viewer_subject)
      refute Policies.subject_can_view_policies?(billing_manager_subject)
    end
  end

  describe "subject_can_manage_policies?/1" do
    test "is true for owner + admin (they hold manage_policies)" do
      {_owner, account, owner_subject} = Fixtures.Subjects.owner_subject()
      assert Policies.subject_can_manage_policies?(owner_subject)

      admin = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :admin)
      assert Policies.subject_can_manage_policies?(admin)
    end

    test "is false for operator, viewer, and an api_client" do
      {_owner, account, _owner_subject} = Fixtures.Subjects.owner_subject()

      operator =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :operator)

      viewer =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :viewer)

      refute Policies.subject_can_manage_policies?(operator)
      refute Policies.subject_can_manage_policies?(viewer)

      {_raw, api_key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)
      refute Policies.subject_can_manage_policies?(Subject.for_api_key(api_key, account))
    end
  end

  describe "policy_management_capabilities/1" do
    test "separates role, runner, and pack authority using current membership access" do
      {_owner, account, owner} = Fixtures.Subjects.owner_subject()
      membership = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
      admin = Fixtures.Subjects.membership_subject(membership)

      assert Policies.policy_management_capabilities(admin) == %{
               can_manage?: true,
               has_runner_access?: true,
               can_manage_scoped?: true,
               can_manage_account?: true
             }

      {:ok, runner_restricted} = RunnerAccess.restricted(["db"], [])

      {:ok, _updated} =
        Accounts.update_membership_runner_access(membership, runner_restricted, owner)

      assert Policies.policy_management_capabilities(admin) == %{
               can_manage?: true,
               has_runner_access?: true,
               can_manage_scoped?: true,
               can_manage_account?: false
             }

      {:ok, pack_restricted} = RunnerAccess.new(:all, [], [], :restricted, ["postgres"])

      {:ok, _updated} =
        Accounts.update_membership_runner_access(membership, pack_restricted, owner)

      assert Policies.policy_management_capabilities(admin) == %{
               can_manage?: true,
               has_runner_access?: true,
               can_manage_scoped?: false,
               can_manage_account?: false
             }
    end
  end

  describe "subject_can_manage_scoped_policies?/1" do
    test "allows a runner-restricted admin with full pack access" do
      {_owner, account, owner} = Fixtures.Subjects.owner_subject()
      membership = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
      admin = Fixtures.Subjects.membership_subject(membership)
      {:ok, restricted} = RunnerAccess.restricted(["db"], [])
      {:ok, _updated} = Accounts.update_membership_runner_access(membership, restricted, owner)

      assert Policies.subject_can_manage_scoped_policies?(admin)
    end
  end

  describe "subject_can_manage_account_policy?/1" do
    test "requires full runner and pack access" do
      {_owner, account, owner} = Fixtures.Subjects.owner_subject()
      membership = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
      admin = Fixtures.Subjects.membership_subject(membership)

      assert Policies.subject_can_manage_account_policy?(admin)

      {:ok, restricted} = RunnerAccess.restricted(["db"], [])
      {:ok, _updated} = Accounts.update_membership_runner_access(membership, restricted, owner)

      refute Policies.subject_can_manage_account_policy?(admin)
    end
  end

  describe "seed_policy/3" do
    test "inserts the account's default policy and is idempotent (on_conflict: nothing)" do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      assert {:ok, %Policy{} = seeded} = Policies.seed_policy(account.id, user.id)
      assert seeded.account_id == account.id
      assert seeded.scope_type == :account
      # Seeds the conservative stock defaults.
      assert seeded.rules["defaults"]["high"] == "require_approval"
      assert seeded.rules["defaults"]["critical"] == "deny"

      # A second seed for the same account is a no-op — still one live policy.
      assert {:ok, _} = Policies.seed_policy(account.id, user.id)
      assert Policies.peek_policy_for_account(account.id).id == seeded.id
    end

    test "accepts an explicit rules map for the bootstrap" do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      assert {:ok, seeded} = Policies.seed_policy(account.id, user.id, allow_all_rules())
      assert seeded.rules["defaults"]["critical"] == "allow"
    end
  end

  describe "peek_policy_for_account/1" do
    test "returns the account's default policy struct, never a scoped override" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      {:ok, _scoped} = Policies.save_scoped_rules(deny_all_rules(), :runner, runner.id, subject)

      assert %Policy{scope_type: :account, account_id: account_id} =
               Policies.peek_policy_for_account(account.id)

      assert account_id == account.id
    end

    test "returns nil when the account has no policy (the default-deny signal)" do
      account = Fixtures.Accounts.create_account()
      assert is_nil(Policies.peek_policy_for_account(account.id))
    end
  end

  describe "evaluate/2 — risk-tier defaults" do
    setup do
      %{policy: %Policy{rules: Policies.default_rules()}}
    end

    test "no policy means deny everything" do
      assert Policies.evaluate(nil, %{"action_id" => "x.y"}) ==
               {:deny, [], "No policy is configured for this account, so this action was denied."}
    end

    test "malformed stored sections fail closed instead of raising" do
      rules = %{"defaults" => "not a map", "overrides" => "not a list"}
      policy = %Policy{rules: rules}

      assert {:deny, [], _reason} =
               Policies.evaluate(policy, %{"action_id" => "linux.uptime", "risk" => "low"})

      assert Policies.shadowed_overrides(rules) == []

      outcome = Policies.simulate_outcome(rules, %{"linux.uptime" => :low})
      assert outcome["deny"] == %{count: 1, examples: ["linux.uptime"]}
    end

    test "low/medium tier defaults to allow with stock defaults", %{policy: policy} do
      assert {:allow, [], _} =
               Policies.evaluate(policy, %{"action_id" => "x", "risk" => "low"})

      assert {:allow, [], _} =
               Policies.evaluate(policy, %{"action_id" => "x", "risk" => "medium"})
    end

    test "high tier defaults to require_approval", %{policy: policy} do
      assert {:require_approval, [], _} =
               Policies.evaluate(policy, %{"action_id" => "x", "risk" => "high"})
    end

    test "critical tier defaults to deny", %{policy: policy} do
      assert {:deny, [], _} =
               Policies.evaluate(policy, %{"action_id" => "x", "risk" => "critical"})
    end

    test "operator can flip a single tier's default" do
      rules =
        Policies.default_rules()
        |> Map.update!("defaults", &Map.put(&1, "critical", "require_approval"))

      policy = %Policy{rules: rules}

      assert {:require_approval, [], _} =
               Policies.evaluate(policy, %{"action_id" => "x", "risk" => "critical"})
    end
  end

  describe "evaluate/2 — per-action overrides" do
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
                 %{"action_id" => "x.bad", "risk" => "low"}
               )

      assert reason == "The account policy rule “block-bad” denies this low-risk action."

      assert {:allow, [], _} =
               Policies.evaluate(
                 %Policy{rules: rules},
                 %{"action_id" => "x.fine", "risk" => "low"}
               )
    end

    test "override reasons combine scope, rule, decision, and risk" do
      rules = %{
        "defaults" => %{"high" => "deny"},
        "overrides" => [
          %{
            "name" => "permit status checks",
            "action" => "cassandra.status_*",
            "decision" => "allow"
          }
        ]
      }

      policy = %Policy{scope_type: :group, scope_value: "va1-cassandra", rules: rules}

      assert Policies.evaluate(policy, %{
               "action_id" => "cassandra.status_ring",
               "risk" => "high"
             }) ==
               {:allow, ["permit status checks"],
                "The “va1-cassandra” group policy rule “permit status checks” allows this high-risk action."}
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
                 %{"action_id" => "cassandra.status_check", "risk" => "high"}
               )

      assert {:deny, [], _} =
               Policies.evaluate(
                 %Policy{rules: rules},
                 %{"action_id" => "cassandra.drop", "risk" => "high"}
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
                 %{"action_id" => "cassandra.DROP_table", "risk" => "low"}
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
                 %{"action_id" => "linux.uptime", "risk" => "low"}
               )
    end

    test "unknown tier falls back to deny" do
      rules = %{"schema_version" => 2, "defaults" => %{}, "overrides" => []}

      assert {:deny, [], _} =
               Policies.evaluate(
                 %Policy{rules: rules},
                 %{"action_id" => "x", "risk" => "low"}
               )
    end

    test "the evaluator ignores `kind` in match_ctx — action_id + risk decide" do
      # `kind` was dead plumbing in the evaluator: overrides match on the
      # action glob and defaults on the risk tier. Passing it (any value)
      # must not change the verdict.
      policy = %Policy{rules: Policies.default_rules()}

      base = %{"action_id" => "x", "risk" => "high"}

      assert Policies.evaluate(policy, base) ==
               Policies.evaluate(policy, Map.put(base, "kind", "exec"))

      assert Policies.evaluate(policy, base) ==
               Policies.evaluate(policy, Map.put(base, "kind", "anything-else"))
    end
  end

  describe "simulate_outcome/2" do
    test "buckets each catalog action by its decision under the live rules" do
      rules = %{
        "defaults" => %{
          "low" => "allow",
          "medium" => "allow",
          "high" => "require_approval",
          "critical" => "deny"
        },
        # An override moves a specific action to a different bucket than its tier.
        "overrides" => [
          %{"name" => "reads", "action" => "linux.uptime", "decision" => "require_approval"}
        ]
      }

      catalog = %{
        # low → allow by tier, but the override sends it to require_approval
        "linux.uptime" => :low,
        "docker.ps" => :low,
        "nginx.reload" => :medium,
        "linux.reboot_host" => :high,
        "wipe.disk" => :critical
      }

      outcome = Policies.simulate_outcome(rules, catalog)

      assert outcome["allow"] == %{count: 2, examples: ["docker.ps", "nginx.reload"]}

      assert outcome["require_approval"] == %{
               count: 2,
               examples: ["linux.reboot_host", "linux.uptime"]
             }

      assert outcome["deny"] == %{count: 1, examples: ["wipe.disk"]}
    end

    test "every decision is present — an empty catalog is 0/[] across the board" do
      outcome = Policies.simulate_outcome(Policies.default_rules(), %{})

      for decision <- ["allow", "require_approval", "deny"] do
        assert outcome[decision] == %{count: 0, examples: []}
      end
    end

    test "precompiles wildcard overrides and keeps only the first three sorted examples" do
      rules = %{
        "defaults" => %{"low" => "allow"},
        "overrides" => [
          %{"name" => "review-drops", "action" => "*.drop_*", "decision" => "require_approval"},
          # First match wins, so this later exact deny never moves a.drop_table out
          # of the review bucket.
          %{"name" => "deny-a-drop", "action" => "a.drop_table", "decision" => "deny"}
        ]
      }

      ordinary_actions = Map.new(1..1_000, &{"linux.action_#{&1}", :low})

      catalog =
        Map.merge(ordinary_actions, %{
          "d.drop_table" => :low,
          "b.drop_table" => :low,
          "a.drop_table" => :low,
          "c.drop_table" => :low
        })

      outcome = Policies.simulate_outcome(rules, catalog)

      assert outcome["allow"] == %{
               count: 1_000,
               examples: ["linux.action_1", "linux.action_10", "linux.action_100"]
             }

      assert outcome["require_approval"] == %{
               count: 4,
               examples: ["a.drop_table", "b.drop_table", "c.drop_table"]
             }

      assert outcome["deny"] == %{count: 0, examples: []}
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

  # Allow/deny-everything rule shapes for the scoped-CRUD describes above.
  # A persisted member of `account` whose runner access is narrowed to `groups`,
  # granted through the real mutation so the scope rows match production.
  defp restricted_member(account, granting_subject, role, groups) do
    membership = Fixtures.Memberships.create_membership(account_id: account.id, role: role)
    {:ok, access} = RunnerAccess.restricted(groups, [])

    {:ok, _updated} =
      Accounts.update_membership_runner_access(membership, access, granting_subject)

    Fixtures.Subjects.membership_subject(membership)
  end

  # A runner in `group` advertising one trusted low-risk action, so the compiler
  # can freeze a real plan item against it.
  defp trusted_runner(account, subject, group) do
    runner = Fixtures.Runners.create_runner(account_id: account.id, group: group)
    hash = Fixtures.Catalog.pack_hash("policies-test")

    payload = %{
      "hostname" => runner.hostname,
      "version" => runner.runner_version,
      "labels" => runner.labels,
      "enforce_signatures" => false,
      "packs" => %{"linux-core" => %{"version" => "1.4.2", "hash" => hash}},
      "actions" => [
        %{
          "id" => "linux.uptime",
          "pack_id" => "linux-core",
          "title" => "Uptime",
          "kind" => "exec",
          "risk" => "low",
          "summary" => "Reports uptime",
          "description" => "Reports uptime",
          "side_effects" => [],
          "args" => [],
          "examples" => [],
          "search_terms" => []
        }
      ]
    }

    assert {:ok, runner} = Catalog.observe_state(runner, payload)

    for version <- Fixtures.Catalog.list_pack_versions(account.id) do
      assert {:ok, _version} = Catalog.trust_pack_version(version.id, subject)
    end

    runner
  end

  defp compile_uptime_plan(subject, group) do
    definition = %{
      "schema_version" => 1,
      "context_markdown" => "",
      "inputs" => [],
      "stages" => [
        %{
          "id" => "inspect",
          "title" => "Inspect",
          "mode" => "parallel",
          "max_parallel" => 5,
          "steps" => [
            %{
              "id" => "uptime",
              "pack" => %{"id" => "linux-core"},
              "action" => "linux.uptime",
              "targets" => %{"selection" => "all", "refs" => ["group:" <> group]},
              "args" => %{},
              "outputs" => [],
              "success" => [],
              "wait" => nil
            }
          ]
        }
      ]
    }

    Compiler.compile(definition, %{}, "policies-test-seed", subject)
  end

  defp require_approval_rules(approval) do
    %{
      "schema_version" => 2,
      "defaults" => %{
        "low" => "require_approval",
        "medium" => "require_approval",
        "high" => "require_approval",
        "critical" => "require_approval"
      },
      "overrides" => [],
      "approval" => %{
        "min_approvals" => Keyword.fetch!(approval, :min_approvals),
        "allow_self_approval" => Keyword.fetch!(approval, :allow_self_approval)
      }
    }
  end

  defp allow_all_rules do
    %{
      "schema_version" => 2,
      "defaults" => %{
        "low" => "allow",
        "medium" => "allow",
        "high" => "allow",
        "critical" => "allow"
      },
      "overrides" => [],
      "approval" => %{"min_approvals" => 1, "allow_self_approval" => true}
    }
  end

  defp deny_all_rules do
    %{
      "schema_version" => 2,
      "defaults" => %{"low" => "deny", "medium" => "deny", "high" => "deny", "critical" => "deny"},
      "overrides" => [],
      "approval" => %{"min_approvals" => 1, "allow_self_approval" => true}
    }
  end
end
