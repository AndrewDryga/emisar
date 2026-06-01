defmodule EmisarWeb.PacksLiveTest do
  use EmisarWeb.ConnCase, async: true

  describe "GET /app/packs" do
    test "redirects anonymous users", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/app/packs")
    end

    test "renders the empty state when the account has no pack observations", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      {:ok, _lv, html} = live(conn, ~p"/app/packs")

      assert html =~ "Packs"
      assert html =~ "No packs reported yet"
    end
  end
end
