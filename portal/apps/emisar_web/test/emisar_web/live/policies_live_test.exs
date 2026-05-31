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

    test "loading an existing policy reflects its defaults + overrides in the form", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)

      # Hand-craft a policy directly so we control the JSON shape.
      existing = Policies.peek_policy_for_account(account.id)
      subject = Emisar.Fixtures.subject_for(user, account)

      {:ok, _} =
        Policies.update_rules(
          existing,
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
end
