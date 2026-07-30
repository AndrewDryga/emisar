defmodule EmisarWeb.AccountRedirectControllerTest do
  @moduledoc """
  Slugless `/app` URLs forward to the current account's canonical slugged
  pages — including the `/app/agents` deep-link shorthands the MCP installer
  and `emisar-mcp --help` print without knowing the account.
  """
  use EmisarWeb.ConnCase, async: true

  describe "GET /app" do
    test "forwards to the current account, slugged", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      conn = get(conn, ~p"/app")
      assert redirected_to(conn) == "/app/#{account.slug}"
    end

    test "an unauthenticated visitor is sent to sign-in", %{conn: conn} do
      conn = get(conn, ~p"/app")
      assert redirected_to(conn) == ~p"/sign_in"
    end
  end

  describe "GET /app/agents" do
    test "forwards to the current account's agents page", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      conn = get(conn, ~p"/app/agents")
      assert redirected_to(conn) == "/app/#{account.slug}/agents"
    end

    test "an unauthenticated visitor is sent to sign-in", %{conn: conn} do
      conn = get(conn, ~p"/app/agents")
      assert redirected_to(conn) == ~p"/sign_in"
    end
  end

  describe "GET /app/agents/connect" do
    test "forwards to the current account's connect flow", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      conn = get(conn, ~p"/app/agents/connect")
      assert redirected_to(conn) == "/app/#{account.slug}/agents/connect"
    end
  end

  describe "GET /app/runbooks" do
    test "forwards list and new links to the current account", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      list_conn = get(conn, ~p"/app/runbooks")
      assert redirected_to(list_conn) == "/app/#{account.slug}/runbooks"

      assert list_conn
             |> recycle()
             |> get(~p"/app/runbooks/new")
             |> redirected_to() == "/app/#{account.slug}/runbooks/new"
    end
  end
end
