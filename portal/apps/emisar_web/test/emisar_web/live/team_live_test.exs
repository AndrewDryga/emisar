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
      assert html =~ "Send invitation"
      refute html =~ "Only owners and admins can invite"
    end
  end

  describe "GET /app/settings/team as a viewer" do
    test "renders the read-only banner instead of the form", %{conn: conn} do
      {conn, user, _account} = register_and_log_in(conn, %{account: %{name: "ViewerOrg"}})

      m = Emisar.Accounts.primary_membership(user)
      {:ok, _} = Emisar.Accounts.update_membership_role(m, "viewer")

      {:ok, _lv, html} = live(conn, ~p"/app/settings/team")

      assert html =~ "Only owners and admins can invite"
      refute html =~ "Send invitation"
    end
  end
end
