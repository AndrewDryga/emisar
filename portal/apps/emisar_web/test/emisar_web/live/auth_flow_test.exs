defmodule EmisarWeb.AuthFlowTest do
  use EmisarWeb.ConnCase, async: true

  describe "GET /sign_in" do
    test "renders the passwordless sign-in form", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/sign_in")
      assert html =~ "Welcome back"
      assert html =~ "Work email"
      assert html =~ "sign-in link"
      # Passwordless: no password field, no forgot-password link.
      refute html =~ "Password"
      refute html =~ "reset_password"
    end

    test "redirects authenticated users to /app", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      assert {:error, {:redirect, %{to: "/app"}}} = live(conn, ~p"/sign_in")
    end
  end

  describe "GET /sign_up" do
    test "renders the registration form (no password to set)", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/sign_up")
      assert html =~ "Start your free workspace"
      assert html =~ "Work email"
      assert html =~ "sign-in link"
      refute html =~ "Password"
    end

    test "redirects authenticated users to /app", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      assert {:error, {:redirect, %{to: "/app"}}} = live(conn, ~p"/sign_up")
    end
  end

  describe "GET /sign_in/magic" do
    test "renders the magic-link request form", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/sign_in/magic")
      assert html =~ "one-time"
      assert html =~ ~s(action="/sign_in/magic/start")
    end
  end
end
