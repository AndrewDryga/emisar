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

    test "stamps a per-request nonce on script-src and reuses it on the inline JSON-LD",
         %{conn: conn} do
      conn = get(conn, ~p"/")
      [csp] = get_resp_header(conn, "content-security-policy")
      [_, nonce] = Regex.run(~r/'nonce-([^']+)'/, csp)

      # script-src carries the nonce (so no 'unsafe-inline' is needed)...
      assert csp =~ "script-src 'self' 'nonce-#{nonce}'"
      # ...and the home page's JSON-LD <script> reuses it, or the browser
      # would block the structured data under script-src 'self'.
      assert html_response(conn, 200) =~ ~s(application/ld+json" nonce="#{nonce}")
    end

    test "uses a fresh nonce on each request", %{conn: conn} do
      nonce = fn conn ->
        [csp] = conn |> get(~p"/") |> get_resp_header("content-security-policy")
        [_, n] = Regex.run(~r/'nonce-([^']+)'/, csp)
        n
      end

      assert nonce.(conn) != nonce.(conn)
    end
  end
end
