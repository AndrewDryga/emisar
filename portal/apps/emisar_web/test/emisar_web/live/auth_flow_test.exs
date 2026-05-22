defmodule EmisarWeb.AuthFlowTest do
  use EmisarWeb.ConnCase, async: true

  describe "GET /sign_in" do
    test "renders the sign-in form", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/sign_in")
      assert html =~ "Welcome back"
      assert html =~ "Work email"
      assert html =~ "Password"
    end

    test "redirects authenticated users to /app", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      assert {:error, {:redirect, %{to: "/app"}}} = live(conn, ~p"/sign_in")
    end
  end

  describe "GET /sign_up" do
    test "renders the registration form", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/sign_up")
      assert html =~ "Start your free workspace"
      assert html =~ "Work email"
      assert html =~ "Password"
    end
  end

  describe "POST /sign_in" do
    setup do
      {:ok, user} =
        Emisar.Accounts.register_user(%{
          email: "test@example.com",
          full_name: "Test User",
          password: "very-long-password-1234"
        })

      {:ok, _user} = Emisar.Accounts.confirm_user(user)
      :ok
    end

    test "logs in with correct credentials", %{conn: conn} do
      conn =
        post(conn, ~p"/sign_in", %{
          "user" => %{
            "email" => "test@example.com",
            "password" => "very-long-password-1234"
          }
        })

      assert redirected_to(conn) == ~p"/app"
      assert get_session(conn, :user_token)
    end

    test "rejects wrong password and preserves email in flash", %{conn: conn} do
      conn =
        post(conn, ~p"/sign_in", %{
          "user" => %{
            "email" => "test@example.com",
            "password" => "not-the-real-one-1234"
          }
        })

      assert redirected_to(conn) == ~p"/sign_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "don't match"
      assert Phoenix.Flash.get(conn.assigns.flash, :email) == "test@example.com"
    end
  end

  describe "GET /reset_password" do
    test "renders the request form", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/reset_password")
      assert html =~ "Reset your password"
    end
  end

  describe "GET /sign_in/magic" do
    test "renders the magic-link form", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/sign_in/magic")
      assert html =~ "Sign in via email"
    end
  end
end
