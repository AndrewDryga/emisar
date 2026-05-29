defmodule EmisarWeb.DashboardLiveTest do
  use EmisarWeb.ConnCase, async: true

  describe "GET /app" do
    test "redirects anonymous users to /sign_in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/app")
    end

    test "renders the empty-state with a pre-minted install command for accounts with zero runners",
         %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      {:ok, _lv, html} = live(conn, ~p"/app")
      assert html =~ "Connect your first runner"
      # The install command is rendered inline — no click required.
      assert html =~ "curl -sSL"
      assert html =~ "EMISAR_AUTH_KEY=emkey-auth-"

      # Mint dropped exactly one auto-generated key into the ring, and
      # because it's auto-unused it stays hidden from operator-facing
      # lists.
      all = Emisar.Repo.all(Emisar.Runners.AuthKey)
      assert length(all) == 1
      assert Emisar.Runners.AuthKey.auto_unused?(hd(all))
      assert Emisar.Runners.list_auth_keys(account.id) == []
    end

    test "renders the populated dashboard once a runner exists", %{conn: conn} do
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
