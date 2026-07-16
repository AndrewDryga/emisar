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

    test "permits only same-origin LiveView websocket connections", %{conn: conn} do
      [csp] = conn |> get(~p"/") |> get_resp_header("content-security-policy")
      assert csp =~ "connect-src 'self'"
      refute csp =~ " wss:"
      refute csp =~ " ws:"
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
    test "merges a page's extra sources into the base policy", %{conn: conn} do
      # A page that needs extra origins (the Paddle /checkout page) assigns a
      # map of directive → extra sources. The plug MERGES them into the base
      # directive's source list — a second same-named directive would be
      # ignored by browsers — and appends net-new directives. Driven through
      # the plug + a send: the policy is computed at send time, because a
      # controller action assigns :csp_extra long after the router pipeline
      # ran this plug.
      conn =
        conn
        |> Plug.Conn.assign(:csp_extra, %{
          "script-src" => ["https://cdn.paddle.com"],
          "frame-src" => ["https://buy.paddle.com"]
        })
        |> EmisarWeb.Plugs.ContentSecurityPolicy.call([])
        |> Plug.Conn.send_resp(200, "ok")

      [csp] = get_resp_header(conn, "content-security-policy")

      # The widened directive keeps its base sources and gains the extra…
      assert csp =~ ~r/script-src 'self' 'nonce-[^']+' https:\/\/cdn\.paddle\.com/
      # …a net-new directive is appended…
      assert csp =~ "frame-src https://buy.paddle.com"
      # …and every base directive is still intact.
      assert csp =~ "default-src 'self'"
      assert csp =~ "frame-ancestors 'none'"
      assert csp =~ "object-src 'none'"
    end

    test "no csp_extra leaves the base policy unchanged", %{conn: conn} do
      conn =
        conn
        |> EmisarWeb.Plugs.ContentSecurityPolicy.call([])
        |> Plug.Conn.send_resp(200, "ok")

      [csp] = get_resp_header(conn, "content-security-policy")

      refute csp =~ "paddle.com"
      assert String.ends_with?(csp, "object-src 'none'")
    end

    test "the dev mailbox HTML document can be framed only by its same origin", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/dev/mailbox/message-id/html")
        |> EmisarWeb.Plugs.ContentSecurityPolicy.call([])
        |> EmisarWeb.Plugs.MailboxPreviewCSP.call([])
        |> Plug.Conn.send_resp(200, "email")

      [csp] = get_resp_header(conn, "content-security-policy")

      assert csp =~ "frame-ancestors 'self'"
      refute csp =~ "frame-ancestors 'none'"
    end

    test "other mailbox and application pages remain unframeable", %{conn: conn} do
      for path <- ["/dev/mailbox/message-id", "/app/demo"] do
        response =
          conn
          |> Map.put(:request_path, path)
          |> EmisarWeb.Plugs.ContentSecurityPolicy.call([])
          |> EmisarWeb.Plugs.MailboxPreviewCSP.call([])
          |> Plug.Conn.send_resp(200, "page")

        [csp] = get_resp_header(response, "content-security-policy")
        assert csp =~ "frame-ancestors 'none'"
      end
    end
  end
end
