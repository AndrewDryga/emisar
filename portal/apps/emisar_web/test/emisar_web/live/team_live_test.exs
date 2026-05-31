defmodule EmisarWeb.TeamLiveTest do
  @moduledoc """
  Regression test for #112: TeamLive showed "Only owners and admins can
  invite" to a user whose role WAS owner because `can_manage?(assigns)`
  was being called with the bare assigns map instead of a socket-shaped
  struct and the pattern match failed.
  """

  use EmisarWeb.ConnCase, async: true

  describe "GET /app/settings/team as an owner" do
    test "renders the invite form (not the read-only banner)", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, _lv, html} = live(conn, ~p"/app/settings/team")

      assert html =~ "Invite a teammate"
      assert html =~ "Send invite"
      refute html =~ "Only owners and admins can invite"
    end
  end

  describe "GET /app/settings/team as a viewer" do
    test "renders the read-only banner instead of the form", %{conn: conn} do
      {conn, user, _account} = register_and_log_in(conn, %{account: %{name: "ViewerOrg"}})

      {:ok, m} = Emisar.Accounts.fetch_primary_membership_for_user(user)
      _ = Emisar.Fixtures.force_membership_role(m, "viewer")

      {:ok, _lv, html} = live(conn, ~p"/app/settings/team")

      assert html =~ "Only owners and admins can invite"
      refute html =~ "Send invite"
    end
  end

  describe "runner-scope editor (#238)" do
    test "owner can save a group + runner scope for an invited admin", %{conn: conn} do
      {conn, owner, account} = register_and_log_in(conn, %{account: %{name: "ScopeOrg"}})

      # An invited admin we'll scope.
      email = "scoped-#{System.unique_integer([:positive])}@example.com"

      subject = Emisar.Fixtures.subject_for(owner, account, role: :owner)
      {:ok, %{membership: m}} =
        Emisar.Accounts.invite_user_to_account(email, "admin", subject)

      # A runner the scope can target.
      {:ok, runner} =
        Emisar.Runners.create_runner(%{"name" => "r1", "group" => "dba"}, subject)

      {:ok, lv, html} = live(conn, ~p"/app/settings/team")

      # Default state — no scopes = "all runners" label rendered.
      assert html =~ "access: all runners"

      # Open the inline editor for the invited admin.
      render_click(lv, "start_scope_edit", %{"membership_id" => m.id})

      # Submit a scope with one group + one runner.
      render_submit(
        element(lv, "form[phx-submit='save_scopes']"),
        %{
          "membership_id" => m.id,
          "groups" => ["dba"],
          "runners" => [runner.id]
        }
      )

      # Persisted as two scope rows.
      scopes = Emisar.Accounts.runner_scopes_for_membership(m.id)
      assert Enum.any?(scopes, &(&1.scope_type == "group" and &1.scope_value == "dba"))
      assert Enum.any?(scopes, &(&1.scope_type == "runner" and &1.scope_value == runner.id))
    end
  end
end
