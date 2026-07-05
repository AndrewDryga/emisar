defmodule EmisarWeb.PoliciesLiveTest do
  @moduledoc """
  Exercises the policy editor: the default policy (risk-tier defaults +
  per-action overrides) and the inline targeted-ruleset list (add → pick a
  runner/group → save). Each card is its own form, discriminated by an
  `editor` field — `"account"` or a ruleset uid — so saves persist the
  expected v2 JSON shape `Emisar.Policies.evaluate/3` consumes.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Policies

  describe "GET /app/policies" do
    test "redirects anonymous users", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/app/anon/policies")
    end

    test "renders the default policy + ruleset sections with the empty placeholders", %{
      conn: conn
    } do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/policies")

      assert html =~ "Default policy"
      assert html =~ "Per-action overrides"
      assert html =~ "Targeted rulesets"

      # Defaults render every tier with a select.
      assert html =~ ~s(name="policy[defaults][low]")
      assert html =~ ~s(name="policy[defaults][medium]")
      assert html =~ ~s(name="policy[defaults][high]")
      assert html =~ ~s(name="policy[defaults][critical]")

      # The seeded default has no overrides and no rulesets — for a manager
      # the dashed composers ARE the empty states (no placeholder hints).
      assert html =~ "Add override"
      assert html =~ "Add ruleset"
    end

    test "a tier select disables decisions below its floor and pre-selects the current value", %{
      conn: conn
    } do
      # Seeded defaults are low/medium=allow, high=require_approval, critical=deny.
      # The critical floor is the high tier's rank (require_approval), so "Allow"
      # would be more permissive than high and is rendered disabled-but-visible;
      # the stored "deny" is pre-selected. This is the per-option state the
      # shared <.select> must carry through (options_for_select can't).
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/policies")

      [critical] =
        Regex.run(~r/name="policy\[defaults\]\[critical\]".*?<\/select>/s, html)

      assert critical =~ ~r/<option(?=[^>]*\bvalue="allow")(?=[^>]*\bdisabled)[^>]*>/
      assert critical =~ ~r/<option(?=[^>]*\bvalue="deny")(?=[^>]*\bselected)[^>]*>/
      refute critical =~ ~r/<option(?=[^>]*\bvalue="deny")(?=[^>]*\bdisabled)[^>]*>/
    end

    test "tweak defaults + add an override → save → persisted as v2 JSON", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/policies")

      # Add an empty override row to the account editor.
      lv |> render_click("add_override", %{"editor" => "account"})

      # Fill defaults + the new override via a change event — the save
      # handler re-syncs from the submitted params before persisting.
      lv
      |> form("#policy-form-account", %{
        "policy" => %{
          "defaults" => %{
            "low" => "allow",
            "medium" => "allow",
            "high" => "require_approval",
            "critical" => "deny"
          },
          "overrides" => %{
            "0" => %{
              "name" => "allow-cassandra-status",
              "action" => "cassandra.status_*",
              "decision" => "allow"
            }
          }
        }
      })
      |> render_change()

      lv |> form("#policy-form-account") |> render_submit()

      policy = Policies.peek_policy_for_account(account.id)

      assert policy.rules == %{
               "schema_version" => 2,
               "defaults" => %{
                 "low" => "allow",
                 "medium" => "allow",
                 "high" => "require_approval",
                 "critical" => "deny"
               },
               "overrides" => [
                 %{
                   "name" => "allow-cassandra-status",
                   "action" => "cassandra.status_*",
                   "decision" => "allow"
                 }
               ],
               # The editor always emits the approval section; untouched, it
               # carries the single-approver defaults.
               "approval" => %{"min_approvals" => 1, "allow_self_approval" => true}
             }
    end

    test "blank-action override rows are dropped on save", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/policies")

      lv |> render_click("add_override", %{"editor" => "account"})

      lv
      |> form("#policy-form-account", %{
        "policy" => %{
          "defaults" => %{
            "low" => "allow",
            "medium" => "allow",
            "high" => "require_approval",
            "critical" => "deny"
          },
          "overrides" => %{
            "0" => %{"name" => "", "action" => "", "decision" => "allow"}
          }
        }
      })
      |> render_change()

      lv |> form("#policy-form-account") |> render_submit()

      policy = Policies.peek_policy_for_account(account.id)
      assert policy.rules["overrides"] == []
    end

    test "remove_override drops the row from the account form", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/policies")

      lv |> render_click("add_override", %{"editor" => "account"})
      lv |> render_click("add_override", %{"editor" => "account"})

      html =
        lv
        |> form("#policy-form-account", %{
          "policy" => %{
            "overrides" => %{
              "0" => %{"name" => "first", "action" => "linux.*", "decision" => "allow"},
              "1" => %{"name" => "second", "action" => "cassandra.*", "decision" => "deny"}
            }
          }
        })
        |> render_change()

      assert html =~ "first"
      assert html =~ "second"

      html = lv |> render_click("remove_override", %{"editor" => "account", "index" => "0"})

      refute html =~ ~s(value="first")
      assert html =~ ~s(value="second")
    end

    test "removing an override then saving persists the removal and audits it as removed", %{
      conn: conn
    } do
      # `remove_override` is an in-memory edit; the removal
      # only takes effect on the next Save. After saving, the persisted rules drop
      # the override AND the `policy.updated` audit diff records it under
      # `changes.overrides.removed` (the LV mutation reaches the same context write
      # + diff the API does).
      {conn, user, account} = register_and_log_in(conn)
      subject = Fixtures.Subjects.subject_for(user, account)

      # Seed a saved default carrying one override (the "before" the diff compares).
      {:ok, _} =
        Policies.save_rules(
          %{
            "schema_version" => 2,
            "defaults" => %{
              "low" => "allow",
              "medium" => "allow",
              "high" => "require_approval",
              "critical" => "deny"
            },
            "overrides" => [
              %{"name" => "drop-me", "action" => "linux.reboot", "decision" => "deny"}
            ]
          },
          subject
        )

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/policies")
      assert html =~ "drop-me"

      # Remove the only override row, then save the default card.
      lv |> render_click("remove_override", %{"editor" => "account", "index" => "0"})
      lv |> form("#policy-form-account") |> render_submit()

      # The override is gone from the persisted rules…
      policy = Policies.peek_policy_for_account(account.id)
      assert policy.rules["overrides"] == []

      # …and the latest policy.updated audit records it as removed.
      {:ok, events, _} =
        Emisar.Audit.list_events(subject, filter: [event_type: ["policy.updated"]])

      latest = hd(events)
      removed = latest.payload["changes"]["overrides"]["removed"]
      assert Enum.any?(removed, &(&1["action"] == "linux.reboot"))
    end

    test "warns when an override is shadowed by an earlier broader glob (deny copy)", %{
      conn: conn
    } do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/policies")

      lv |> render_click("add_override", %{"editor" => "account"})
      lv |> render_click("add_override", %{"editor" => "account"})

      # A broad allow above a specific deny: first-match means the deny is dead.
      html =
        lv
        |> form("#policy-form-account", %{
          "policy" => %{
            "overrides" => %{
              "0" => %{"name" => "allow-nginx", "action" => "nginx_*", "decision" => "allow"},
              "1" => %{"name" => "block-reload", "action" => "nginx_reload", "decision" => "deny"}
            }
          }
        })
        |> render_change()

      assert html =~ "Shadowed by rule 1 above"
      # The deny case gets the sharpened copy.
      assert html =~ "this <strong>deny</strong>"
    end

    test "no shadow warning when the specific deny comes first", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/policies")

      lv |> render_click("add_override", %{"editor" => "account"})
      lv |> render_click("add_override", %{"editor" => "account"})

      html =
        lv
        |> form("#policy-form-account", %{
          "policy" => %{
            "overrides" => %{
              "0" => %{"name" => "block-reload", "action" => "nginx_reload", "decision" => "deny"},
              "1" => %{"name" => "allow-nginx", "action" => "nginx_*", "decision" => "allow"}
            }
          }
        })
        |> render_change()

      refute html =~ "Shadowed by rule"
    end

    test "a valid edit saves cleanly — the rules error is a defensive inline net, never a flash",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/policies")

      # The tier defaults are constrained <select>s and form_change auto-enforces
      # monotonicity, so the UI can't produce an invalid policy — a valid edit
      # saves cleanly. The changeset's `:rules` error renders inline, never a flash.
      html =
        lv
        |> form("#policy-form-account", %{
          "policy" => %{"defaults" => %{"medium" => "require_approval"}}
        })
        |> render_submit()

      assert html =~ "Policy saved."
      refute html =~ "Could not save policy"
      refute html =~ "higher-risk tiers must be at least as restrictive"
    end

    test "loading an existing policy reflects its defaults + overrides in the form", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = Fixtures.Subjects.subject_for(user, account)

      {:ok, _} =
        Policies.save_rules(
          %{
            "schema_version" => 2,
            "defaults" => %{
              "low" => "allow",
              "medium" => "require_approval",
              "high" => "deny",
              "critical" => "deny"
            },
            "overrides" => [
              %{"name" => "linux-status-only", "action" => "linux.*", "decision" => "allow"}
            ]
          },
          subject
        )

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/policies")

      assert html =~ "linux-status-only"
      assert html =~ "linux.*"

      assert html =~
               ~r/name="policy\[defaults\]\[medium\]".*?<option value="require_approval" selected/s
    end

    test "approval requirements round-trip through the editor (2 approvers, no self-approval)",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/policies")

      # An unchecked self-approval checkbox sends only the hidden "false"; the
      # number input sends "2". Push the change as the browser would.
      render_change(lv, "form_change", %{
        "editor" => "account",
        "policy" => %{
          "defaults" => %{
            "low" => "allow",
            "medium" => "allow",
            "high" => "require_approval",
            "critical" => "deny"
          },
          "approval" => %{"min_approvals" => "2", "allow_self_approval" => "false"}
        }
      })

      lv |> form("#policy-form-account") |> render_submit()

      policy = Policies.peek_policy_for_account(account.id)
      assert policy.rules["approval"] == %{"min_approvals" => 2, "allow_self_approval" => false}
    end

    test "an existing min_approvals reflects in the editor's number input", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = Fixtures.Subjects.subject_for(user, account)

      {:ok, _} =
        Policies.save_rules(
          %{
            "schema_version" => 2,
            "approval" => %{"min_approvals" => 3, "allow_self_approval" => false}
          },
          subject
        )

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/policies")

      assert html =~ ~r/name="policy\[approval\]\[min_approvals\]"[^>]*value="3"/

      # allow_self_approval=false ("a different operator") is the stored state, so the
      # value="false" radio renders checked and value="true" does not.
      assert html =~
               ~r/<input[^>]*type="radio"[^>]*name="policy\[approval\]\[allow_self_approval\]"[^>]*value="false"[^>]*checked/

      refute html =~
               ~r/<input[^>]*type="radio"[^>]*name="policy\[approval\]\[allow_self_approval\]"[^>]*value="true"[^>]*checked/

      # A healthy gate (3 approvals from a different operator) needs no callout — the
      # cards + count already say what it does, so the amber warning box stays hidden.
      refute html =~ "the requester may approve their own request"
      refute html =~ "add independent review"
    end

    test "the required-approvals label pluralizes with the count", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = Fixtures.Subjects.subject_for(user, account)

      {:ok, _} =
        Policies.save_rules(
          %{
            "schema_version" => 2,
            "approval" => %{"min_approvals" => 1, "allow_self_approval" => false}
          },
          subject
        )

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/policies")

      # One approval — singular, and "distinct" drops (nothing to be distinct from).
      assert html =~ "operator, before the action runs"
      refute html =~ "operators, before the action runs"

      {:ok, _} =
        Policies.save_rules(
          %{
            "schema_version" => 2,
            "approval" => %{"min_approvals" => 2, "allow_self_approval" => false}
          },
          subject
        )

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/policies")

      assert html =~ "distinct operators, before the action runs"
    end

    test "self-approval + a single approval folds the warning into the in-effect line", %{
      conn: conn
    } do
      {conn, user, account} = register_and_log_in(conn)
      subject = Fixtures.Subjects.subject_for(user, account)

      {:ok, _} =
        Policies.save_rules(
          %{
            "schema_version" => 2,
            "approval" => %{"min_approvals" => 1, "allow_self_approval" => true}
          },
          subject
        )

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/policies")

      # The verdict states the effect AND folds in the guidance in one place
      # (no separate warning banner).
      assert html =~ "the requester may approve their own request"
      assert html =~ "Choose a different operator, or raise the count, to add independent review"
      refute html =~ "Self-approval is allowed and only one approval is required"
    end

    test "a config with independent review shows no single-reviewer guidance", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = Fixtures.Subjects.subject_for(user, account)

      {:ok, _} =
        Policies.save_rules(
          %{
            "schema_version" => 2,
            "approval" => %{"min_approvals" => 2, "allow_self_approval" => true}
          },
          subject
        )

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/policies")

      # Two approvals means a second person must sign off even if the requester is one —
      # a real gate, so no single-reviewer warning box.
      refute html =~ "the requester may approve their own request"
      refute html =~ "add independent review"
    end

    test "a healthy four-eyes gate shows no verdict callout", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = Fixtures.Subjects.subject_for(user, account)

      {:ok, _} =
        Policies.save_rules(
          %{
            "schema_version" => 2,
            "approval" => %{"min_approvals" => 1, "allow_self_approval" => false}
          },
          subject
        )

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/policies")

      # One approval from a different operator is a real gate — the callout is reserved
      # for the weak self-single-approval case, so nothing shows here.
      refute html =~ "add independent review"
      refute html =~ "the requester may approve their own request"
    end

    test "an operator sees the policy read-only — no manage affordances, save denied", %{
      conn: conn
    } do
      # operator holds `view` (page renders) but not `manage`,
      # so it reads identically to the viewer case: the read-only notice, no Add /
      # Save controls, and a crafted save re-checks `subject_can_manage_policies?`
      # and is denied.
      {_owner_conn, _owner, account} = register_and_log_in(conn)

      operator = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      {:ok, lv, html} =
        build_conn() |> log_in_user(operator) |> live(~p"/app/#{account}/policies")

      assert html =~ "only owners and admins can change it"
      refute html =~ "Add ruleset"
      refute html =~ "Save default policy"

      assert render_hook(lv, "save", %{"editor" => "account"}) =~ "have permission to do that"
    end

    test "a viewer's default-policy card is fully inert — no add/trash, inputs disabled", %{
      conn: conn
    } do
      # for a
      # non-manager every editing affordance on the (default) policy card is
      # removed or disabled: no "Add override" button, the existing override row's
      # trash is hidden, every tier <select> is `disabled`, and the approval gate's
      # min_approvals number + self-approval checkbox are `disabled`. The Save gate
      # is defense-in-depth on top; the card simply offers nothing to submit.
      {_owner_conn, owner, account} = register_and_log_in(conn)
      owner_subject = Fixtures.Subjects.subject_for(owner, account)

      # Seed a saved default carrying one override so the trash button has a row
      # to (not) render on.
      {:ok, _} =
        Policies.save_rules(
          %{
            "schema_version" => 2,
            "defaults" => %{
              "low" => "allow",
              "medium" => "allow",
              "high" => "require_approval",
              "critical" => "deny"
            },
            "overrides" => [
              %{"name" => "block-drops", "action" => "*.drop_*", "decision" => "deny"}
            ],
            "approval" => %{"min_approvals" => 2, "allow_self_approval" => false}
          },
          owner_subject
        )

      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      {:ok, _lv, html} = build_conn() |> log_in_user(viewer) |> live(~p"/app/#{account}/policies")

      # The override row is shown (read-only)…
      assert html =~ ~s(value="block-drops")
      # no "Add override" button anywhere.
      refute html =~ "Add override"
      # no per-row trash (its phx-click handler is absent).
      refute html =~ ~s(phx-click="remove_override")
      # every risk-tier <select> element is disabled.
      for tier <- ["low", "medium", "high", "critical"] do
        assert html =~ ~r/<select[^>]*name="policy\[defaults\]\[#{tier}\]"[^>]*disabled/
      end

      # the approval-gate inputs are disabled (attribute order varies,
      # so match the tag with order-agnostic lookaheads).
      assert html =~
               ~r/<input(?=[^>]*\bname="policy\[approval\]\[min_approvals\]")(?=[^>]*\bdisabled)[^>]*>/

      assert html =~
               ~r/<input(?=[^>]*\btype="radio")(?=[^>]*\bname="policy\[approval\]\[allow_self_approval\]")(?=[^>]*\bdisabled)[^>]*>/
    end

    test "another account's default policy + rulesets never appear on this page", %{conn: conn} do
      # `fetch_policy` / `list_scoped_policies` scope to the
      # subject's account via `for_subject`, so a foreign account's saved default
      # and runner ruleset are invisible here.
      {conn, _user, account} = register_and_log_in(conn)

      {_b_conn, b_user, b_account} = register_and_log_in(build_conn())
      b_subject = Fixtures.Subjects.subject_for(b_user, b_account)

      b_runner =
        Fixtures.Runners.create_runner(
          account_id: b_account.id,
          name: "account-b-only-runner",
          group: "b-secret-group"
        )

      {:ok, _} = Policies.save_scoped_rules(deny_all(), :runner, b_runner.id, b_subject)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/policies")

      refute html =~ "account-b-only-runner"
      refute html =~ "b-secret-group"
      # A's own page shows an empty ruleset stack (just the composer), not
      # B's ruleset.
      assert html =~ "Add ruleset"
      refute html =~ "Replaces the default policy for this"
    end

    test "remove_override with a non-integer index is a no-op", %{conn: conn} do
      # `Integer.parse("abc")` is `:error`, so the handler
      # returns the socket unchanged. The existing override row survives.
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/policies")

      lv |> render_click("add_override", %{"editor" => "account"})

      html =
        lv
        |> form("#policy-form-account", %{
          "policy" => %{
            "overrides" => %{
              "0" => %{"name" => "keep-me", "action" => "linux.*", "decision" => "allow"}
            }
          }
        })
        |> render_change()

      assert html =~ ~s(value="keep-me")

      html = lv |> render_hook("remove_override", %{"editor" => "account", "index" => "abc"})
      assert html =~ ~s(value="keep-me")
    end

    test "remove_override with an out-of-range index is safe", %{conn: conn} do
      # `List.delete_at/2` past the end returns the list
      # unchanged, so removing index 5 of a single-row list is a no-op, no crash.
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/policies")

      lv |> render_click("add_override", %{"editor" => "account"})

      html =
        lv
        |> form("#policy-form-account", %{
          "policy" => %{
            "overrides" => %{
              "0" => %{"name" => "still-here", "action" => "nginx_*", "decision" => "deny"}
            }
          }
        })
        |> render_change()

      assert html =~ ~s(value="still-here")

      html = lv |> render_hook("remove_override", %{"editor" => "account", "index" => "5"})
      assert html =~ ~s(value="still-here")
    end

    test "raising a lower tier auto-bumps the higher tiers (monotonic enforcement)", %{conn: conn} do
      # posting low=deny runs `enforce_monotonic_defaults`,
      # lifting medium/high/critical up to at least deny. The rendered selects all
      # reflect deny, and the would-be-invalid combo never reaches the operator.
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/policies")

      html =
        render_change(lv, "form_change", %{
          "editor" => "account",
          "policy" => %{"defaults" => %{"low" => "deny"}}
        })

      for tier <- ["low", "medium", "high", "critical"] do
        assert html =~
                 ~r/name="policy\[defaults\]\[#{tier}\]".*?<option value="deny" selected/s
      end
    end

    test "an unknown tier decision keeps the prior value (merge_defaults whitelist)", %{
      conn: conn
    } do
      # `merge_defaults/2` only accepts a value in
      # `@decisions`; a junk POST for a tier falls back to the editor's current
      # value. The seeded high default is require_approval and stays that way.
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/policies")

      html =
        render_change(lv, "form_change", %{
          "editor" => "account",
          "policy" => %{"defaults" => %{"high" => "obliterate"}}
        })

      assert html =~
               ~r/name="policy\[defaults\]\[high\]".*?<option value="require_approval" selected/s
    end

    test "the client mirror equals the server check — an auto-bumped combo saves clean", %{
      conn: conn
    } do
      # the LV's `decision_at_rank/1` uses the same
      # `Policies.decision_rank/1` as the changeset's monotonicity check. Posting
      # low=deny, high=allow is auto-monotonized client-side to all-deny, so the
      # rendered form carries no rules error and the result the client produced
      # is accepted by the server on save (no transient-invalid state).
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/policies")

      html =
        render_change(lv, "form_change", %{
          "editor" => "account",
          "policy" => %{"defaults" => %{"low" => "deny", "high" => "allow"}}
        })

      refute html =~ "higher-risk tiers must be at least as restrictive"

      html = lv |> form("#policy-form-account") |> render_submit()
      assert html =~ "Policy saved."
      refute html =~ "higher-risk tiers must be at least as restrictive"

      policy = Policies.peek_policy_for_account(account.id)

      assert policy.rules["defaults"] == %{
               "low" => "deny",
               "medium" => "deny",
               "high" => "deny",
               "critical" => "deny"
             }
    end

    test "a non-numeric min_approvals falls back to the prior value", %{conn: conn} do
      # (LV half) — `parse_min_approvals/2` keeps the prior
      # editor value when the posted string isn't a parseable integer ≥ 1. The
      # seeded default is 1, so a junk post leaves the number input at 1.
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/policies")

      html =
        render_change(lv, "form_change", %{
          "editor" => "account",
          "policy" => %{"approval" => %{"min_approvals" => "not-a-number"}}
        })

      assert html =~ ~r/name="policy\[approval\]\[min_approvals\]"[^>]*value="1"/
    end
  end

  describe "targeted rulesets" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      %{conn: conn, account: account, subject: Fixtures.Subjects.subject_for(user, account)}
    end

    test "an existing runner ruleset renders as a card labelled with the runner name", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      runner =
        Fixtures.Runners.create_runner(account_id: account.id, name: "web-1", group: "web")

      {:ok, _} = Policies.save_scoped_rules(deny_all(), :runner, runner.id, subject)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/policies")

      assert html =~ "Default policy"
      assert html =~ "Targeted rulesets"
      # The card shows the runner name, its own Save, and a Remove.
      assert html =~ "web-1"
      assert html =~ "Save ruleset"
      assert html =~ "Remove"
    end

    test "a ruleset whose runner was deleted falls back to the runner id, still renders", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      # `runner_name/2` resolves the saved ruleset's runner id
      # against the live (non-deleted) runner list; a since-deleted runner isn't in
      # it, so the card falls back to the raw id rather than crashing — the ruleset
      # stays identifiable so an operator can remove the now-dangling override.
      runner =
        Fixtures.Runners.create_runner(account_id: account.id, name: "ghost-1", group: "web")

      {:ok, _} = Policies.save_scoped_rules(deny_all(), :runner, runner.id, subject)

      # Soft-delete the runner — it drops out of `@runners`, so the label resolver
      # can't find a name for the saved scope.
      Emisar.Runners.Runner.Query.all()
      |> Emisar.Runners.Runner.Query.by_id(runner.id)
      |> Emisar.Repo.update_all(set: [deleted_at: DateTime.utc_now()])

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/policies")

      # The deleted runner's name is gone; the card identifies the scope by its id.
      refute html =~ "ghost-1"
      assert html =~ runner.id
      assert html =~ "Remove"
    end

    test "remove_ruleset with an unknown uid is a no-op (no crash)", %{
      conn: conn,
      account: account
    } do
      # `find_ruleset/2` returns nil for a uid that matches no
      # card, so the handler short-circuits to `{:noreply, socket}` — no DB call, no
      # crash, the page is unchanged.
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/policies")

      before = render(lv)
      # Dispatch the event directly (the button doesn't exist for this uid); it
      # returns without raising and leaves the rendered page identical.
      render_hook(lv, "remove_ruleset", %{"uid" => "new-does-not-exist"})
      assert render(lv) == before
    end

    test "a scoped ruleset weaker than the strict default warns the operator", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      # A strict account default: two approvers, no self-approval.
      {:ok, _} =
        Policies.save_rules(
          %{
            "schema_version" => 2,
            "approval" => %{"min_approvals" => 2, "allow_self_approval" => false}
          },
          subject
        )

      runner = Fixtures.Runners.create_runner(account_id: account.id, name: "web-1", group: "web")
      # deny_all/0 carries no approval section → the scoped gate reads as the lax
      # default (1 approver, self-approval allowed), i.e. weaker than the default.
      {:ok, _} = Policies.save_scoped_rules(deny_all(), :runner, runner.id, subject)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/policies")

      assert html =~ "Weaker approval gate than the default policy"
      assert html =~ "requires fewer approvals (1 vs 2)"
      assert html =~ "lets the requester approve their own action"
    end

    test "a scoped ruleset at least as strict as the default shows no warning", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id, name: "web-1", group: "web")
      # The account default is the lax baseline (1 approver, self-approval on), so
      # a deny_all ruleset matches it — nothing weaker to warn about.
      {:ok, _} = Policies.save_scoped_rules(deny_all(), :runner, runner.id, subject)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/policies")

      refute html =~ "Weaker approval gate than the default policy"
    end

    test "add a ruleset → pick a runner → save → persists a runner-scoped policy", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      runner =
        Fixtures.Runners.create_runner(account_id: account.id, name: "web-1", group: "web")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/policies")

      lv |> render_click("add_ruleset", %{})

      # Pick the runner target on the new (unsaved) card — the change fires on
      # the picker form, which carries the ruleset uid as a hidden field.
      html =
        lv
        |> form(~s(form[phx-change="set_target"]), %{"target" => "runner:" <> runner.id})
        |> render_change()

      # The card now exposes its policy form (Save ruleset).
      assert html =~ "Save ruleset"

      lv |> form(~s(form[id^="policy-form-new-"])) |> render_submit()

      assert {:ok, [policy]} = Policies.list_scoped_policies(subject)
      assert policy.scope_type == :runner
      assert policy.scope_value == runner.id
    end

    test "save rejects a :runner scope not in the account (crafted set_target)", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      # A crafted set_target carrying a runner id outside the account (IL-15) must
      # not persist an inert `(account, :runner, <foreign>)` row. Driven via
      # render_hook (a raw event) because the real picker only offers in-account
      # runners — which is exactly the gate a crafted event tries to skip.
      foreign_runner_id = Ecto.UUID.generate()

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/policies")

      html = lv |> render_click("add_ruleset", %{})
      [uid] = Regex.run(~r/new-\d+/, html)

      render_hook(lv, "set_target", %{"uid" => uid, "target" => "runner:" <> foreign_runner_id})

      html = lv |> form(~s(form[id^="policy-form-new-"])) |> render_submit()

      assert html =~ "in this account"

      # The crafted scope persisted nothing — no override exists.
      assert {:ok, []} = Policies.list_scoped_policies(subject)
    end

    test "add a ruleset → pick a group → save → persists a group-scoped policy", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      _runner =
        Fixtures.Runners.create_runner(account_id: account.id, name: "n1", group: "prod")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/policies")

      lv |> render_click("add_ruleset", %{})

      lv
      |> form(~s(form[phx-change="set_target"]), %{"target" => "group:prod"})
      |> render_change()

      lv |> form(~s(form[id^="policy-form-new-"])) |> render_submit()

      assert {:ok, [policy]} = Policies.list_scoped_policies(subject)
      assert policy.scope_type == :group
      assert policy.scope_value == "prod"
    end

    test "the target picker lists groups as selectable options with their runners nested", %{
      conn: conn,
      account: account
    } do
      runner =
        Fixtures.Runners.create_runner(account_id: account.id, name: "web-1", group: "web")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/policies")
      html = lv |> render_click("add_ruleset", %{})

      # One combined tree: the group is a selectable <option> (not an <optgroup>
      # label that can't be picked), and its runner is an <option> too — no
      # separate runners-vs-groups categories.
      assert html =~ ~s(value="group:web")
      assert html =~ ~s(value="runner:#{runner.id}")
      assert html =~ "web-1"
      refute html =~ "<optgroup"
    end

    test "a target another ruleset already claims renders disabled in a new picker", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      # The picker shows every runner/group, but one already bound to a saved
      # ruleset is disabled-but-visible so the operator sees why it can't be
      # re-targeted. This per-option `disabled` is exactly why the picker uses
      # the shared <.select> rather than <.input type="select">.
      runner =
        Fixtures.Runners.create_runner(account_id: account.id, name: "web-1", group: "web")

      {:ok, _} = Policies.save_scoped_rules(deny_all(), :runner, runner.id, subject)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/policies")
      html = lv |> render_click("add_ruleset", %{})

      # In the new (unsaved) card's picker, the taken runner is disabled and
      # labelled as already having a ruleset.
      assert html =~ ~r/<option(?=[^>]*\bvalue="runner:#{runner.id}")(?=[^>]*\bdisabled)[^>]*>/
      assert html =~ "web-1 — has a ruleset"
    end

    test "removing a saved ruleset falls the scope back to the default policy", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      runner =
        Fixtures.Runners.create_runner(account_id: account.id, name: "db-1", group: "db")

      {:ok, saved} = Policies.save_scoped_rules(deny_all(), :runner, runner.id, subject)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/policies")
      html = lv |> render_click("remove_ruleset", %{"uid" => saved.id})

      assert html =~ "Ruleset removed"
      assert {:ok, []} = Policies.list_scoped_policies(subject)
    end

    test "a viewer sees the policy read-only and a forged save is denied", %{account: account} do
      _runner =
        Fixtures.Runners.create_runner(account_id: account.id, name: "web-1", group: "web")

      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      {:ok, lv, html} = build_conn() |> log_in_user(viewer) |> live(~p"/app/#{account}/policies")

      # No management affordances: no "Add ruleset", no Save buttons.
      refute html =~ "Add ruleset"
      refute html =~ "Save default policy"
      assert html =~ "only owners and admins can change it"

      # A forged save event is refused at the handler (apostrophe is HTML-escaped).
      assert render_hook(lv, "save", %{"editor" => "account"}) =~ "have permission to do that"
    end

    test "an operator's crafted remove_ruleset is denied and the ruleset survives", %{
      account: account,
      subject: subject
    } do
      # removing a SAVED ruleset is a real mutation, so the
      # handler runs `Permissions.gated` on `subject_can_manage_policies?`. An
      # operator (view-only) is refused with a flash; the ruleset is not deleted.
      runner =
        Fixtures.Runners.create_runner(account_id: account.id, name: "db-1", group: "db")

      {:ok, saved} = Policies.save_scoped_rules(deny_all(), :runner, runner.id, subject)

      operator = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      {:ok, lv, _html} =
        build_conn() |> log_in_user(operator) |> live(~p"/app/#{account}/policies")

      assert render_hook(lv, "remove_ruleset", %{"uid" => saved.id}) =~
               "have permission to do that"

      # The ruleset is still there.
      assert {:ok, [_]} = Policies.list_scoped_policies(subject)
    end

    test "a viewer's crafted remove_ruleset is denied", %{
      account: account,
      subject: subject
    } do
      # (viewer half) — same gate, the laxest role.
      runner =
        Fixtures.Runners.create_runner(account_id: account.id, name: "db-2", group: "db")

      {:ok, saved} = Policies.save_scoped_rules(deny_all(), :runner, runner.id, subject)

      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      {:ok, lv, _html} =
        build_conn() |> log_in_user(viewer) |> live(~p"/app/#{account}/policies")

      assert render_hook(lv, "remove_ruleset", %{"uid" => saved.id}) =~
               "have permission to do that"

      assert {:ok, [_]} = Policies.list_scoped_policies(subject)
    end

    test "an operator's crafted add_ruleset is a no-op — no card added", %{
      account: account
    } do
      # `add_ruleset` re-checks `subject_can_manage_policies?`
      # and, for a non-manager, returns the socket unchanged (a silent no-op — it
      # only appends an in-memory card, so there's nothing to flash). No "Save
      # ruleset" card appears.
      _runner =
        Fixtures.Runners.create_runner(account_id: account.id, name: "web-1", group: "web")

      operator = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      {:ok, lv, html} =
        build_conn() |> log_in_user(operator) |> live(~p"/app/#{account}/policies")

      refute html =~ "Save ruleset"
      refute render_hook(lv, "add_ruleset", %{}) =~ "Save ruleset"
    end

    test "saving a new ruleset twice edits the same row, not a duplicate", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      # after the first save, `replace_saved/3` swaps the
      # card's `new-…` uid for the persisted policy id, so the second save's
      # editor resolves to the existing scope and upserts it. Exactly one
      # runner-scoped policy remains.
      runner = Fixtures.Runners.create_runner(account_id: account.id, name: "web-1", group: "web")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/policies")
      lv |> render_click("add_ruleset", %{})

      lv
      |> form(~s(form[phx-change="set_target"]), %{"target" => "runner:" <> runner.id})
      |> render_change()

      # First save persists the row and rebuilds the card under the policy id.
      lv |> form(~s(form[id^="policy-form-new-"])) |> render_submit()
      assert {:ok, [policy]} = Policies.list_scoped_policies(subject)

      # The card now submits under the policy id, not `new-…`.
      html = render(lv)
      assert html =~ ~s(id="policy-form-#{policy.id}")
      refute html =~ ~s(id="policy-form-new-)

      # Second save edits the same scope — still exactly one runner ruleset.
      lv |> form(~s(form[id="policy-form-#{policy.id}"])) |> render_submit()

      {:ok, scoped} = Policies.list_scoped_policies(subject)
      assert Enum.count(scoped, &(&1.scope_type == :runner and &1.scope_value == runner.id)) == 1
    end

    test "two adds get distinct uids — both cards' forms coexist", %{
      conn: conn,
      account: account
    } do
      # each add stamps a fresh `new-<unique_integer>` uid,
      # so the editor-discriminated forms don't collide. Two adds → two distinct
      # `policy-form-new-…` ids (after each picks a target to reveal its form).
      _r1 = Fixtures.Runners.create_runner(account_id: account.id, name: "web-1", group: "web")
      _r2 = Fixtures.Runners.create_runner(account_id: account.id, name: "db-1", group: "db")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/policies")

      lv |> render_click("add_ruleset", %{})
      html = lv |> render_click("add_ruleset", %{})

      # Two separate picker forms, each carrying its own hidden uid.
      uids = Regex.scan(~r/name="uid" value="(new-\d+)"/, html, capture: :all_but_first)
      assert length(uids) == 2
      assert uids |> List.flatten() |> Enum.uniq() |> length() == 2
    end

    test "Add ruleset is disabled once every runner and group is taken", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      # `addable_any?/3` gates the button: a runner is one
      # runner target AND one group target, so saving a ruleset for both leaves
      # nothing free. The button renders disabled-but-visible.
      runner =
        Fixtures.Runners.create_runner(account_id: account.id, name: "only-1", group: "only")

      {:ok, _} = Policies.save_scoped_rules(deny_all(), :runner, runner.id, subject)
      {:ok, _} = Policies.save_scoped_rules(deny_all(), :group, "only", subject)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/policies")

      assert render(lv) =~
               ~r/<button(?=[^>]*phx-click="add_ruleset")(?=[^>]*\bdisabled)[^>]*>/
    end

    test "an unsaved card seeds from the default's deny-overrides — can't silently widen", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      # the live default carries a deny-override; a new card
      # seeds from that editor (replace-semantics safety), so the deny-override
      # rides into the new card rather than starting from a blank, wider posture.
      {:ok, _} =
        Policies.save_rules(
          %{
            "schema_version" => 2,
            "overrides" => [
              %{"name" => "block-drop", "action" => "*.drop_*", "decision" => "deny"}
            ]
          },
          subject
        )

      _runner =
        Fixtures.Runners.create_runner(account_id: account.id, name: "web-1", group: "web")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/policies")
      lv |> render_click("add_ruleset", %{})

      # Pick a target to reveal the new card's policy form, then read its overrides.
      html =
        lv
        |> form(~s(form[phx-change="set_target"]), %{"target" => "group:web"})
        |> render_change()

      assert html =~ ~s(value="*.drop_*")
      assert html =~ ~s(value="block-drop")
    end

    test "retargeting an unsaved card overwrites the prior scope", %{
      conn: conn,
      account: account
    } do
      # the picker form stays on an unsaved card, so picking
      # a second target rewrites scope_type/scope_value to the latest choice.
      runner =
        Fixtures.Runners.create_runner(account_id: account.id, name: "web-1", group: "prod")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/policies")
      lv |> render_click("add_ruleset", %{})

      # First pick the runner.
      lv
      |> form(~s(form[phx-change="set_target"]), %{"target" => "runner:" <> runner.id})
      |> render_change()

      # Then retarget to the group — the option marked selected is now the group.
      html =
        lv
        |> form(~s(form[phx-change="set_target"]), %{"target" => "group:prod"})
        |> render_change()

      assert html =~ ~r/<option(?=[^>]*\bvalue="group:prod")(?=[^>]*\bselected)[^>]*>/
      refute html =~ ~r/<option(?=[^>]*\bvalue="runner:#{runner.id}")(?=[^>]*\bselected)[^>]*>/
    end

    test "an unparseable target clears the scope back to the picker", %{
      conn: conn,
      account: account
    } do
      # a target string without a `runner:`/`group:` prefix
      # → `parse_target/1` returns `{nil, ""}`, so the card reverts to its
      # "Pick a runner or group above" prompt and hides the rules editor.
      runner = Fixtures.Runners.create_runner(account_id: account.id, name: "web-1", group: "web")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/policies")
      html = lv |> render_click("add_ruleset", %{})

      # The picker form carries the card's uid as a hidden field — read it so a
      # crafted, prefix-less target can be posted (a real <select> change can't
      # send an out-of-options value).
      [uid] = Regex.run(~r/name="uid" value="(new-\d+)"/, html, capture: :all_but_first)

      # Set a real scope first so there's something to clear.
      html =
        lv
        |> form(~s(form[phx-change="set_target"]), %{"target" => "runner:" <> runner.id})
        |> render_change()

      assert html =~ "Save ruleset"

      # Now post a prefix-less target — `parse_target/1` → `{nil, ""}`, so the
      # scope clears and the rules editor disappears.
      html = render_change(lv, "set_target", %{"uid" => uid, "target" => "garbage-no-prefix"})

      refute html =~ "Save ruleset"
      assert html =~ "Pick a runner or group above"
    end

    test "a malformed set_target event (no keys) is a no-op", %{conn: conn, account: account} do
      # the `set_target/2` catch-all clause handles an event
      # missing `uid`/`target`: the socket is returned unchanged, no crash.
      _runner =
        Fixtures.Runners.create_runner(account_id: account.id, name: "web-1", group: "web")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/policies")
      lv |> render_click("add_ruleset", %{})

      # A crafted event with neither key still leaves the page alive and the new
      # card on its picker prompt.
      html = render_hook(lv, "set_target", %{})
      assert html =~ "Pick a runner or group above"
    end

    test "add_override on a ruleset card appends to that editor only and defaults to allow", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      # the `editor` discriminator routes the
      # append to the saved ruleset's card; the new row carries the empty-override
      # shape (decision "allow") and is scoped to that card, not the account one.
      runner = Fixtures.Runners.create_runner(account_id: account.id, name: "web-1", group: "web")
      {:ok, saved} = Policies.save_scoped_rules(deny_all(), :runner, runner.id, subject)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/policies")

      html = lv |> render_click("add_override", %{"editor" => saved.id})

      # The row lands on the ruleset card's form with the allow default.
      # (`<.input type="select">` emits `selected` before `value`.)
      assert html =~ ~s(name="policy[overrides][0][action]")

      assert html =~
               ~r/name="policy\[overrides\]\[0\]\[decision\]".*?<option selected[^>]*value="allow"/s

      # The account card got no override row.
      [account_form] =
        Regex.run(~r/<form id="policy-form-account".*?<\/form>/s, html)

      refute account_form =~ ~s(name="policy[overrides][0][action]")
    end

    test "remove_override on a ruleset card drops the row from that editor", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      # removing an override on a saved ruleset card targets
      # that editor via the `editor` discriminator; the row is gone from its form.
      runner = Fixtures.Runners.create_runner(account_id: account.id, name: "db-1", group: "db")

      {:ok, saved} =
        Policies.save_scoped_rules(
          Map.put(deny_all(), "overrides", [
            %{"name" => "scoped-one", "action" => "linux.*", "decision" => "allow"}
          ]),
          :runner,
          runner.id,
          subject
        )

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/policies")
      assert html =~ ~s(value="scoped-one")

      html = lv |> render_click("remove_override", %{"editor" => saved.id, "index" => "0"})
      refute html =~ ~s(value="scoped-one")
    end
  end

  defp deny_all do
    %{
      "schema_version" => 2,
      "defaults" => %{"low" => "deny", "medium" => "deny", "high" => "deny", "critical" => "deny"},
      "overrides" => []
    }
  end
end
