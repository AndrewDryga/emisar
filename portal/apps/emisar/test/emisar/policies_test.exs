defmodule Emisar.PoliciesTest do
  use Emisar.DataCase, async: true
  alias Emisar.Auth.Subject
  alias Emisar.Fixtures
  alias Emisar.Policies
  alias Emisar.Policies.Policy

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
        assert {:error, :invalid_policy_approval} = Policies.approval_settings_for(rules)
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
      assert {"unknown rule sections:" <> _, _} = changeset.errors[:rules]
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

    test "rejects an override without an action" do
      for action <- [nil, "", "   ", 42] do
        changeset =
          rules_changeset(%{"overrides" => [%{"action" => action, "decision" => "deny"}]})

        refute changeset.valid?
        assert {"override action is required", _} = changeset.errors[:rules]
      end
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

      assert {"min_approvals must be an integer between 1 and " <> _, _} =
               changeset.errors[:rules]
    end

    test "rejects a non-boolean allow_self_approval" do
      changeset =
        rules_changeset(%{
          "approval" => %{"min_approvals" => 1, "allow_self_approval" => "yes"}
        })

      refute changeset.valid?
      assert {"allow_self_approval must be a boolean", _} = changeset.errors[:rules]
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
      assert {"unknown approval keys:" <> _, _} = changeset.errors[:rules]
    end

    test "accepts a valid approval section" do
      changeset =
        rules_changeset(%{"approval" => %{"min_approvals" => 2, "allow_self_approval" => false}})

      assert changeset.valid?
    end

    test "rejects either missing approval setting" do
      missing_min = rules_changeset(%{"approval" => %{"allow_self_approval" => false}})
      refute missing_min.valid?
      assert {"min_approvals is required", _} = missing_min.errors[:rules]

      missing_self = rules_changeset(%{"approval" => %{"min_approvals" => 1}})
      refute missing_self.valid?
      assert {"allow_self_approval is required", _} = missing_self.errors[:rules]
    end

    test "rejects a missing approval section after the backfill" do
      changeset =
        Policy.Changeset.create(%{
          account_id: Ecto.UUID.generate(),
          rules: %{"schema_version" => 2, "defaults" => %{"low" => "allow"}}
        })

      refute changeset.valid?
      assert {"approval settings are required", _} = changeset.errors[:rules]
    end

    test "updating with no rules change doesn't bump the version" do
      rules = %{"schema_version" => 2, "defaults" => %{"low" => "allow"}}
      policy = %Policy{vsn: 1, rules: rules}

      changeset = Policy.Changeset.update(policy, %{updated_by_id: Ecto.UUID.generate()})
      assert Ecto.Changeset.get_change(changeset, :vsn) == nil
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

      assert {:error, :unauthorized} = Policies.fetch_policy(api_subject)
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

  describe "list_scoped_policies/1" do
    test "lists the account's scoped overrides, excluding the account default" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      {:ok, scoped} = Policies.save_scoped_rules(allow_all_rules(), :runner, "runner-1", subject)

      assert {:ok, [listed]} = Policies.list_scoped_policies(subject)
      assert listed.id == scoped.id
      # The account default isn't a scoped override, so it never lists here.
      refute listed.scope_type == :account
    end

    test "an operator (view_policies) can list; an api_client cannot" do
      {_owner, account, owner} = Fixtures.Subjects.owner_subject()
      {:ok, _} = Policies.save_scoped_rules(allow_all_rules(), :runner, "runner-1", owner)

      operator =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :operator)

      assert {:ok, [_]} = Policies.list_scoped_policies(operator)

      {_raw, api_key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)
      api_subject = Subject.for_api_key(api_key, account)
      assert {:error, :unauthorized} = Policies.list_scoped_policies(api_subject)
    end

    test "cross-account: never lists another account's overrides" do
      {_user_a, _account_a, subject_a} = Fixtures.Subjects.owner_subject()
      {:ok, _} = Policies.save_scoped_rules(allow_all_rules(), :runner, "runner-1", subject_a)

      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()
      assert {:ok, []} = Policies.list_scoped_policies(subject_b)
    end
  end

  describe "delete_scoped_policy/2" do
    test "soft-deletes an override so its scope falls back to the next-broader scope" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()
      {:ok, policy} = Policies.save_scoped_rules(deny_all_rules(), :runner, "runner-1", subject)

      assert {:ok, deleted} = Policies.delete_scoped_policy(policy, subject)
      assert deleted.id == policy.id
      refute is_nil(deleted.deleted_at)

      # Gone from the editor's list; the scope now resolves to the broader default.
      assert {:ok, []} = Policies.list_scoped_policies(subject)
    end

    test "a viewer can't delete an override (no manage_policies)" do
      {_owner, account, owner} = Fixtures.Subjects.owner_subject()
      {:ok, policy} = Policies.save_scoped_rules(deny_all_rules(), :runner, "runner-1", owner)

      viewer =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :viewer)

      assert {:error, :unauthorized} = Policies.delete_scoped_policy(policy, viewer)
      # The row is untouched — still live.
      assert {:ok, [_]} = Policies.list_scoped_policies(owner)
    end

    test "cross-account: B can't delete A's override (:not_found, row untouched)" do
      {_user_a, _account_a, subject_a} = Fixtures.Subjects.owner_subject()

      {:ok, policy_a} =
        Policies.save_scoped_rules(deny_all_rules(), :runner, "runner-1", subject_a)

      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      # delete_scoped_policy guards with Subject.ensure_in_account (default
      # :not_found), so B is refused without A's override being touched.
      assert {:error, :not_found} = Policies.delete_scoped_policy(policy_a, subject_b)
      assert {:ok, [_]} = Policies.list_scoped_policies(subject_a)
    end
  end

  describe "save_scoped_rules/4" do
    test "creates a runner override, then upserts the same row in place" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()

      assert {:ok, created} = Policies.save_scoped_rules(deny_all_rules(), :runner, "r1", subject)
      assert created.account_id == account.id
      assert created.scope_type == :runner
      assert created.scope_value == "r1"
      assert created.rules["defaults"]["low"] == "deny"

      # A second save of the same scope is an upsert: same row, bumped vsn.
      assert {:ok, updated} =
               Policies.save_scoped_rules(allow_all_rules(), :runner, "r1", subject)

      assert updated.id == created.id
      assert updated.vsn == created.vsn + 1
      assert updated.rules["defaults"]["low"] == "allow"
    end

    test "rejects an empty scope_value for a runner/group scope" do
      {_user, _account, subject} = Fixtures.Subjects.owner_subject()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Policies.save_scoped_rules(deny_all_rules(), :runner, "", subject)

      assert %{scope_value: [_ | _]} = errors_on(changeset)
    end

    test "a viewer can't save a scoped override (no manage_policies)" do
      {_owner, account, _owner_subject} = Fixtures.Subjects.owner_subject()

      viewer =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :viewer)

      assert {:error, :unauthorized} =
               Policies.save_scoped_rules(deny_all_rules(), :runner, "r1", viewer)
    end

    test "cross-account: B's save never mutates A's same-named override" do
      {_user_a, _account_a, subject_a} = Fixtures.Subjects.owner_subject()
      {:ok, runner_a} = Policies.save_scoped_rules(deny_all_rules(), :runner, "r1", subject_a)

      {_user_b, account_b, subject_b} = Fixtures.Subjects.owner_subject()
      {:ok, runner_b} = Policies.save_scoped_rules(allow_all_rules(), :runner, "r1", subject_b)

      # B's write is a distinct row in B's account; A's deny override is intact.
      assert runner_b.account_id == account_b.id
      refute runner_b.id == runner_a.id

      assert {:ok, [fetched_a]} = Policies.list_scoped_policies(subject_a)
      assert fetched_a.id == runner_a.id
      assert fetched_a.rules["defaults"]["low"] == "deny"
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
      {:ok, _scoped} = Policies.save_scoped_rules(deny_all_rules(), :runner, "r1", subject)

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
      assert {:deny, [], reason} = Policies.evaluate(nil, %{"action_id" => "x.y"})
      assert reason =~ "no policy"
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

      assert reason =~ "Override:"

      assert {:allow, [], _} =
               Policies.evaluate(
                 %Policy{rules: rules},
                 %{"action_id" => "x.fine", "risk" => "low"}
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
