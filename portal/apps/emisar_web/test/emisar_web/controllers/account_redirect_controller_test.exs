defmodule EmisarWeb.AccountRedirectControllerTest do
  @moduledoc """
  Slugless `/app` URLs forward to the current account's canonical slugged pages,
  so installers, CLIs, and public docs can deep-link without knowing the account.
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
    {"/app/sso", "/settings/sso"},
    {"/app/sso/new", "/settings/sso/new"},
    {"/app/billing", "/settings/billing"}
  ]

  describe "current-account redirects" do
    test "each shorthand forwards to the current account's canonical page", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

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
  end
end
