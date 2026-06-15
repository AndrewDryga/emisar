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
      assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/app/policies")
    end

    test "renders the default policy + ruleset sections with the empty placeholders", %{
      conn: conn
    } do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, _lv, html} = live(conn, ~p"/app/policies")

      assert html =~ "Default policy"
      assert html =~ "Risk-tier defaults"
      assert html =~ "Per-action overrides"
      assert html =~ "Targeted rulesets"

      # Defaults render every tier with a select.
      assert html =~ ~s(name="policy[defaults][low]")
      assert html =~ ~s(name="policy[defaults][medium]")
      assert html =~ ~s(name="policy[defaults][high]")
      assert html =~ ~s(name="policy[defaults][critical]")

      # The seeded default has no overrides and no rulesets → both placeholders.
      assert html =~ "No overrides"
      assert html =~ "No targeted rulesets"
    end

    test "tweak defaults + add an override → save → persisted as v2 JSON", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/policies")

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
      {:ok, lv, _html} = live(conn, ~p"/app/policies")

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
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/policies")

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

    test "a valid edit saves cleanly — the rules error is a defensive inline net, never a flash",
         %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/policies")

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
      subject = Emisar.Fixtures.subject_for(user, account)

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

      {:ok, _lv, html} = live(conn, ~p"/app/policies")

      assert html =~ "linux-status-only"
      assert html =~ "linux.*"

      assert html =~
               ~r/name="policy\[defaults\]\[medium\]".*?<option value="require_approval" selected/s
    end

    test "approval requirements round-trip through the editor (2 approvers, no self-approval)",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/policies")

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
      subject = Emisar.Fixtures.subject_for(user, account)

      {:ok, _} =
        Policies.save_rules(
          %{
            "schema_version" => 2,
            "approval" => %{"min_approvals" => 3, "allow_self_approval" => false}
          },
          subject
        )

      {:ok, _lv, html} = live(conn, ~p"/app/policies")

      assert html =~ ~r/name="policy\[approval\]\[min_approvals\]"[^>]*value="3"/
    end
  end

  describe "targeted rulesets" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      %{conn: conn, account: account, subject: Emisar.Fixtures.subject_for(user, account)}
    end

    test "an existing runner ruleset renders as a card labelled with the runner name", ctx do
      runner =
        Emisar.Fixtures.runner_fixture(account_id: ctx.account.id, name: "web-1", group: "web")

      {:ok, _} = Policies.save_scoped_rules(deny_all(), :runner, runner.id, ctx.subject)

      {:ok, _lv, html} = live(ctx.conn, ~p"/app/policies")

      assert html =~ "Default policy"
      assert html =~ "Targeted rulesets"
      # The card shows the runner name, its own Save, and a Remove.
      assert html =~ "web-1"
      assert html =~ "Save ruleset"
      assert html =~ "Remove"
    end

    test "add a ruleset → pick a runner → save → persists a runner-scoped policy", ctx do
      runner =
        Emisar.Fixtures.runner_fixture(account_id: ctx.account.id, name: "web-1", group: "web")

      {:ok, lv, _html} = live(ctx.conn, ~p"/app/policies")

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

      assert {:ok, policy} = Policies.fetch_scoped_policy(:runner, runner.id, ctx.subject)
      assert policy.scope_type == :runner
      assert policy.scope_value == runner.id
    end

    test "add a ruleset → pick a group → save → persists a group-scoped policy", ctx do
      _runner =
        Emisar.Fixtures.runner_fixture(account_id: ctx.account.id, name: "n1", group: "prod")

      {:ok, lv, _html} = live(ctx.conn, ~p"/app/policies")

      lv |> render_click("add_ruleset", %{})

      lv
      |> form(~s(form[phx-change="set_target"]), %{"target" => "group:prod"})
      |> render_change()

      lv |> form(~s(form[id^="policy-form-new-"])) |> render_submit()

      assert {:ok, policy} = Policies.fetch_scoped_policy(:group, "prod", ctx.subject)
      assert policy.scope_type == :group
      assert policy.scope_value == "prod"
    end

    test "the target picker lists groups as selectable options with their runners nested", ctx do
      runner =
        Emisar.Fixtures.runner_fixture(account_id: ctx.account.id, name: "web-1", group: "web")

      {:ok, lv, _html} = live(ctx.conn, ~p"/app/policies")
      html = lv |> render_click("add_ruleset", %{})

      # One combined tree: the group is a selectable <option> (not an <optgroup>
      # label that can't be picked), and its runner is an <option> too — no
      # separate runners-vs-groups categories.
      assert html =~ ~s(value="group:web")
      assert html =~ ~s(value="runner:#{runner.id}")
      assert html =~ "web-1"
      refute html =~ "<optgroup"
    end

    test "removing a saved ruleset falls the scope back to the default policy", ctx do
      runner =
        Emisar.Fixtures.runner_fixture(account_id: ctx.account.id, name: "db-1", group: "db")

      {:ok, saved} = Policies.save_scoped_rules(deny_all(), :runner, runner.id, ctx.subject)

      {:ok, lv, _html} = live(ctx.conn, ~p"/app/policies")
      html = lv |> render_click("remove_ruleset", %{"uid" => saved.id})

      assert html =~ "Ruleset removed"
      assert {:error, :not_found} = Policies.fetch_scoped_policy(:runner, runner.id, ctx.subject)
    end

    test "a viewer sees the policy read-only and a forged save is denied", ctx do
      _runner =
        Emisar.Fixtures.runner_fixture(account_id: ctx.account.id, name: "web-1", group: "web")

      viewer = Emisar.Fixtures.user_fixture()

      _ =
        Emisar.Fixtures.membership_fixture(
          account_id: ctx.account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      {:ok, lv, html} = build_conn() |> log_in_user(viewer) |> live(~p"/app/policies")

      # No management affordances: no "Add ruleset", no Save buttons.
      refute html =~ "Add ruleset"
      refute html =~ "Save default policy"
      assert html =~ "only owners and admins can change it"

      # A forged save event is refused at the handler (apostrophe is HTML-escaped).
      assert render_hook(lv, "save", %{"editor" => "account"}) =~ "have permission to do that"
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
