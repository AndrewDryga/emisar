defmodule EmisarWeb.AuthFlowTest do
  @moduledoc """
  The signed-out entry points (plan §3 "Sign-in", "Sign-up"): `/sign_in` asks
  which workspace, the workspace's own page offers its ways in, `/sign_up`
  creates a workspace, and `/sign_in/magic` exists only for a code this browser
  asked for. All passwordless.
  """
  use EmisarWeb.ConnCase, async: true

  describe "GET /sign_in" do
    test "asks which workspace, without a password or an email field", %{conn: conn} do
      html = conn |> get(~p"/sign_in") |> html_response(200)

      assert html =~ "Enter your workspace address"
      refute html =~ "Work email"
      refute html =~ "Password"
      refute html =~ "reset_password"
    end

    test "stays open to a signed-in browser: it signs in to another workspace", %{conn: conn} do
      {conn, _owner, _account} = register_and_log_in(conn)
      assert conn |> get(~p"/sign_in") |> html_response(200) =~ "Enter your workspace address"
    end
  end

  describe "GET /app/:workspace/sign_in" do
    test "offers that workspace's passwordless email form", %{conn: conn} do
      account = Fixtures.Accounts.create_account(%{name: "Flow Co"})

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/sign_in")

      assert html =~ "Sign in to Flow Co"
      assert html =~ "Work email"
      assert html =~ "sign-in link"
      refute html =~ "Password"
    end
  end

  describe "GET /sign_up" do
    test "renders the sign-up form (no password to set), signed in or not", %{conn: conn} do
      for conn <- [conn, conn |> register_and_log_in() |> elem(0)] do
        {:ok, _lv, html} = live(conn, ~p"/sign_up")
        assert html =~ "Create your workspace"
        assert html =~ "Work email"
        assert html =~ "sign-in link"
        refute html =~ "Password"
      end
    end
  end

  describe "GET /sign_in/magic" do
    test "with no code requested in this browser goes to the workspace picker", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/sign_in/magic")
    end
  end
end
