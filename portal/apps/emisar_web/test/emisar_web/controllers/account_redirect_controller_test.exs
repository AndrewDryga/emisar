defmodule EmisarWeb.AccountRedirectControllerTest do
  @moduledoc """
  Slugless `/app` URLs forward to a signed-in workspace's canonical slugged
  page, so installers, CLIs, and public docs can deep-link without knowing the
  workspace: with one signed-in workspace they redirect, with several they ask
  which one, keeping the page asked for.
  """
  use EmisarWeb.ConnCase, async: true

  @current_account_redirects [
    {"/app", ""},
    {"/app/runners", "/runners"},
    {"/app/runners/install", "/runners/install"},
    {"/app/runners/keys", "/runners/keys"},
    {"/app/runners/keys/new", "/runners/keys/new"},
    {"/app/runs", "/runs"},
    {"/app/approvals", "/approvals"},
    {"/app/runbooks", "/runbooks"},
    {"/app/runbooks/new", "/runbooks/new"},
    {"/app/runbooks/import", "/runbooks/import"},
    {"/app/policies", "/policies"},
    {"/app/packs", "/packs"},
    {"/app/audit", "/audit"},
    {"/app/audit/export", "/audit/export"},
    {"/app/agents", "/agents"},
    {"/app/agents/connect", "/agents/connect"},
    {"/app/team", "/settings/team"},
    {"/app/team/invite", "/settings/team/invite"},
    {"/app/service-accounts", "/settings/service-accounts"},
    {"/app/sso", "/settings/sso"},
    {"/app/sso/new", "/settings/sso/new"},
    {"/app/billing", "/settings/billing"}
  ]

  describe "slugless redirects" do
    test "with one signed-in workspace each shorthand forwards to its page", %{conn: conn} do
      {conn, _owner, account} = register_and_log_in(conn)

      Enum.reduce(@current_account_redirects, conn, fn {source, destination}, request_conn ->
        redirected_conn = get(request_conn, source)
        assert redirected_to(redirected_conn) == "/app/#{account.slug}#{destination}"
        recycle(redirected_conn)
      end)
    end

    test "each shorthand sends an unauthenticated visitor to sign-in", %{conn: conn} do
      Enum.reduce(@current_account_redirects, conn, fn {source, _destination}, request_conn ->
        redirected_conn = get(request_conn, source)
        assert redirected_to(redirected_conn) == ~p"/sign_in"
        recycle(redirected_conn)
      end)
    end

    test "with several signed-in workspaces each shorthand asks which, keeping the page", %{
      conn: conn
    } do
      {conn, _owner_a, account_a} = register_and_log_in(conn, %{account: %{name: "Alpha Ops"}})
      {conn, _owner_b, account_b} = register_and_log_in(conn, %{account: %{name: "Bravo Ops"}})

      for {source, destination} <- @current_account_redirects do
        document = conn |> get(source) |> html_response(200) |> LazyHTML.from_document()

        assert document |> LazyHTML.query("h1") |> LazyHTML.text() =~ "Choose a workspace"

        for account <- [account_a, account_b] do
          link = LazyHTML.query(document, ~s(a[href="/app/#{account.slug}#{destination}"]))
          assert LazyHTML.text(link) =~ account.name, "#{source} lost #{destination}"
        end

        assert document |> LazyHTML.query(~s(a[href="/sign_in"])) |> Enum.count() == 1
      end
    end

    test "an unauthenticated visitor's shorthand is remembered for after sign-in", %{conn: conn} do
      conn = get(conn, ~p"/app/runs")

      assert redirected_to(conn) == ~p"/sign_in"
      assert get_session(conn, :user_return_to) == ~p"/app/runs"
    end
  end
end
