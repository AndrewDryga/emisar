defmodule EmisarWeb.Plugs.ContentSecurityPolicyTest do
  use EmisarWeb.ConnCase, async: true

  describe "Content-Security-Policy header" do
    test "is set on every HTML response served through the :browser pipeline", %{conn: conn} do
      conn = get(conn, ~p"/")
      [csp] = get_resp_header(conn, "content-security-policy")

      assert csp =~ "default-src 'self'"
      assert csp =~ "script-src 'self'"
      assert csp =~ "frame-ancestors 'none'"
      assert csp =~ "object-src 'none'"
    end

    test "allows the rsms.me font CDN we actually use", %{conn: conn} do
      [csp] = conn |> get(~p"/") |> get_resp_header("content-security-policy")
      assert csp =~ "https://rsms.me"
    end

    test "permits LiveView websocket connections (wss:)", %{conn: conn} do
      [csp] = conn |> get(~p"/") |> get_resp_header("content-security-policy")
      assert csp =~ "connect-src 'self' wss: ws:"
    end

    test "does NOT allow 'unsafe-eval' in script-src — LV doesn't need it", %{conn: conn} do
      [csp] = conn |> get(~p"/") |> get_resp_header("content-security-policy")
      refute csp =~ "'unsafe-eval'"
    end
  end
end
