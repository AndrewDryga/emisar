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

    test "fonts are self-hosted — no third-party font CDN in the policy", %{conn: conn} do
      [csp] = conn |> get(~p"/") |> get_resp_header("content-security-policy")
      assert csp =~ "font-src 'self'"
      refute csp =~ "rsms.me"
    end

    test "sends Cross-Origin-Opener-Policy: same-origin", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert get_resp_header(conn, "cross-origin-opener-policy") == ["same-origin"]
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

  describe "csp_extra opt-in" do
    test "additively merges a page's extra directives onto the base policy", %{conn: conn} do
      # closes CFG-003-T10
      # A page that needs an extra origin (e.g. Paddle checkout) assigns
      # conn.assigns[:csp_extra]; the plug appends those directives WITHOUT
      # dropping any base directive. Driven through the plug directly so the
      # test owns the assign (no marketing page sets csp_extra today).
      conn =
        conn
        |> Plug.Conn.assign(:csp_extra, ["frame-src https://checkout.paddle.com"])
        |> EmisarWeb.Plugs.ContentSecurityPolicy.call([])

      [csp] = get_resp_header(conn, "content-security-policy")

      # The extra directive is present...
      assert csp =~ "frame-src https://checkout.paddle.com"
      # ...and every base directive is still intact (additive, not replacing).
      assert csp =~ "default-src 'self'"
      assert csp =~ "script-src 'self' 'nonce-"
      assert csp =~ "frame-ancestors 'none'"
      assert csp =~ "object-src 'none'"
    end

    test "no csp_extra leaves the base policy unchanged", %{conn: conn} do
      conn = EmisarWeb.Plugs.ContentSecurityPolicy.call(conn, [])
      [csp] = get_resp_header(conn, "content-security-policy")

      refute csp =~ "paddle.com"
      assert String.ends_with?(csp, "object-src 'none'")
    end
  end
end
