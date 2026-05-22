defmodule EmisarWeb.DashboardLiveTest do
  use EmisarWeb.ConnCase, async: true

  describe "GET /app" do
    test "redirects anonymous users to /sign_in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/app")
    end

    test "renders the empty-state for accounts with zero runners", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, _lv, html} = live(conn, ~p"/app")
      assert html =~ "Connect your first runner"
      assert html =~ "Generate install command"
    end

    test "renders the populated dashboard once an runner exists", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)

      {:ok, _agent} =
        Emisar.Runners.create_runner(account.id, %{
          "name" => "runner-1",
          "group" => "default"
        })

      _ = user

      {:ok, _lv, html} = live(conn, ~p"/app")
      assert html =~ "Runners online"
      assert html =~ "Recent runs"
      refute html =~ "Connect your first runner"
    end
  end
end
