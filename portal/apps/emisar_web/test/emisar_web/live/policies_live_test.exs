defmodule EmisarWeb.PoliciesLiveTest do
  @moduledoc """
  Exercises the two-section policy editor:
  risk-tier defaults + per-action overrides → save → confirm the
  persisted JSON shape matches what `Emisar.Policies.evaluate/3`
  expects (v2 shape).
  """
  use EmisarWeb.ConnCase, async: true

  alias Emisar.Policies

  describe "GET /app/policies" do
    test "redirects anonymous users", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/app/policies")
    end

    test "renders both sections with the empty-overrides placeholder", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, _lv, html} = live(conn, ~p"/app/policies")

      # Risk-tier defaults section is always present.
      assert html =~ "Risk-tier defaults"
      assert html =~ "Per-action overrides"

      # Defaults render every tier with a select.
      assert html =~ ~s(name="policy[defaults][low]")
      assert html =~ ~s(name="policy[defaults][medium]")
      assert html =~ ~s(name="policy[defaults][high]")
      assert html =~ ~s(name="policy[defaults][critical]")

      # The seeded default has no overrides → placeholder visible.
      assert html =~ "No overrides"
    end

    test "tweak defaults + add an override → save → persisted as v2 JSON", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/policies")

      # Add an empty override row to state.
      lv |> render_click("add_override", %{})

      # Fill defaults + the new override via a change event — the save
      # handler reads from socket state populated by form_change.
      lv
      |> form("#policy-form", %{
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

      # Save.
      lv |> form("#policy-form") |> render_submit()

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
               ]
             }
    end

    test "blank-action override rows are dropped on save", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/policies")

      lv |> render_click("add_override", %{})

      lv
      |> form("#policy-form", %{
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

      lv |> form("#policy-form") |> render_submit()

      policy = Policies.peek_policy_for_account(account.id)
      assert policy.rules["overrides"] == []
    end

    test "remove_override drops the row from the form", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/policies")

      # Add two overrides, fill them via a change event, then remove the first.
      lv |> render_click("add_override", %{})
      lv |> render_click("add_override", %{})

      html =
        lv
        |> form("#policy-form", %{
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

      html = lv |> render_click("remove_override", %{"index" => "0"})

      refute html =~ ~s(value="first")
      assert html =~ ~s(value="second")
    end

    test "a valid edit saves cleanly — the rules error is a defensive inline net, never a flash",
         %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, lv, _html} = live(conn, ~p"/app/policies")

      # The tier defaults are constrained <select>s and form_change auto-enforces
      # monotonicity, so the UI can't produce an invalid policy — a valid edit
      # saves cleanly. The changeset's `:rules` error is rendered inline on the
      # form (a server-side safety net), never dumped into a flash.
      html =
        lv
        |> form("#policy-form", %{"policy" => %{"defaults" => %{"medium" => "require_approval"}}})
        |> render_submit()

      assert html =~ "Policy saved."
      refute html =~ "Could not save policy"
      # The inline error slot exists in the template but stays empty on success.
      refute html =~ "higher-risk tiers must be at least as restrictive"
    end

    test "loading an existing policy reflects its defaults + overrides in the form", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)

      # Hand-craft a policy directly so we control the JSON shape.
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
              %{
                "name" => "linux-status-only",
                "action" => "linux.*",
                "decision" => "allow"
              }
            ]
          },
          subject
        )

      {:ok, _lv, html} = live(conn, ~p"/app/policies")

      # The override's name + action are rendered as input values.
      assert html =~ "linux-status-only"
      assert html =~ "linux.*"

      # The "medium" tier select renders "require_approval" as selected.
      assert html =~
               ~r/name="policy\[defaults\]\[medium\]".*?<option value="require_approval" selected/s
    end
  end

  describe "runner / group overrides" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      %{conn: conn, account: account, subject: Emisar.Fixtures.subject_for(user, account)}
    end

    test "an existing override renders as a pill labelled with the runner name", ctx do
      runner =
        Emisar.Fixtures.runner_fixture(account_id: ctx.account.id, name: "web-1", group: "web")

      {:ok, _} = Policies.save_scoped_rules(deny_all(), :runner, runner.id, ctx.subject)

      {:ok, _lv, html} = live(ctx.conn, ~p"/app/policies")

      assert html =~ "Account default"
      assert html =~ "web-1"
    end

    test "picking a runner from the add-picker and saving persists a runner-scoped policy", ctx do
      runner =
        Emisar.Fixtures.runner_fixture(account_id: ctx.account.id, name: "web-1", group: "web")

      {:ok, lv, _html} = live(ctx.conn, ~p"/app/policies")

      # The add-picker switches the editor to the not-yet-saved runner scope.
      html =
        lv
        |> element("select[name='runner_id']")
        |> render_change(%{"runner_id" => runner.id})

      assert html =~ "Runner override · web-1"
      assert html =~ "new"

      lv |> form("#policy-form") |> render_submit()

      assert {:ok, policy} = Policies.fetch_scoped_policy(:runner, runner.id, ctx.subject)
      assert policy.scope_type == :runner
      assert policy.scope_value == runner.id
    end

    test "picking a group from the add-picker and saving persists a group-scoped policy", ctx do
      _runner =
        Emisar.Fixtures.runner_fixture(account_id: ctx.account.id, name: "n1", group: "prod")

      {:ok, lv, _html} = live(ctx.conn, ~p"/app/policies")

      html =
        lv
        |> element("select[name='group']")
        |> render_change(%{"group" => "prod"})

      assert html =~ "Group override · prod"

      lv |> form("#policy-form") |> render_submit()

      assert {:ok, policy} = Policies.fetch_scoped_policy(:group, "prod", ctx.subject)
      assert policy.scope_type == :group
      assert policy.scope_value == "prod"
    end

    test "switching to a saved override loads it and exposes a remove button", ctx do
      runner =
        Emisar.Fixtures.runner_fixture(account_id: ctx.account.id, name: "db-1", group: "db")

      {:ok, _} = Policies.save_scoped_rules(deny_all(), :runner, runner.id, ctx.subject)

      {:ok, lv, _html} = live(ctx.conn, ~p"/app/policies")
      html = lv |> element("button", "db-1") |> render_click()

      assert html =~ "Runner override · db-1"
      assert html =~ "Remove override"
    end

    test "removing an override falls the scope back to the account default", ctx do
      runner =
        Emisar.Fixtures.runner_fixture(account_id: ctx.account.id, name: "db-1", group: "db")

      {:ok, _} = Policies.save_scoped_rules(deny_all(), :runner, runner.id, ctx.subject)

      {:ok, lv, _html} = live(ctx.conn, ~p"/app/policies")
      lv |> element("button", "db-1") |> render_click()
      html = lv |> element("button", "Remove override") |> render_click()

      assert html =~ "Override removed"
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

      # No management affordances: no add-picker, no Save button.
      refute html =~ "Add a runner override"
      refute html =~ ~s(form="policy-form")

      # A forged save event is refused at the handler (apostrophe is HTML-escaped).
      assert render_hook(lv, "save", %{}) =~ "have permission to do that"
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
