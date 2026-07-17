defmodule EmisarWeb.SSORequiredControllerTest do
  @moduledoc """
  The require_sso step-up shim must only show its "sign out and use SSO"
  interstitial to a genuinely non-compliant session — not to anyone who lands
  on the URL from a stale or copied link while their account does not require
  SSO (or their session already satisfies it).
  """
  use EmisarWeb.ConnCase, async: true

  describe "GET /app/:account/sso_required" do
    test "redirects a normal session on an account that does not require SSO", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      conn = get(conn, ~p"/app/#{account}/sso_required")

      assert redirected_to(conn) == ~p"/app/#{account}"
      refute conn.resp_body =~ "requires single sign-on"
    end
  end
end
