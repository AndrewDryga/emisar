defmodule EmisarWeb.SecurityHeadersTest do
  @moduledoc """
  The full secure-header contract on a `:browser` HTML response — the
  headers `put_secure_browser_headers` sets plus the relaxations the CSP
  plug deliberately allows. The nonce / COOP / strict-directive behaviour
  has its own suite (`content_security_policy_test.exs`); this pins the
  rest of the documented header surface so a Phoenix upgrade that drops a
  default, or a careless CSP edit, is caught.
  """
  use EmisarWeb.ConnCase, async: true

  describe "secure browser headers on a :browser response" do
    test "carries the Phoenix secure-header defaults (nosniff, referrer, cross-domain)", %{
      conn: conn
    } do
      conn = get(conn, ~p"/")

      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "referrer-policy") == ["strict-origin-when-cross-origin"]
      assert get_resp_header(conn, "x-permitted-cross-domain-policies") == ["none"]
    end

    test "blocks framing via CSP frame-ancestors, not a legacy X-Frame-Options header", %{
      conn: conn
    } do
      conn = get(conn, ~p"/")
      [csp] = get_resp_header(conn, "content-security-policy")

      # Framing is denied by the modern, more-expressive directive...
      assert csp =~ "frame-ancestors 'none'"
      # ...and we intentionally don't ALSO emit X-Frame-Options (frame-ancestors
      # supersedes it in every browser we support).
      assert get_resp_header(conn, "x-frame-options") == []
    end

    test "our strict CSP overrides the bare default put_secure_browser_headers sets", %{
      conn: conn
    } do
      # put_secure_browser_headers ships a minimal `base-uri 'self'; frame-ancestors
      # 'self';` CSP; our plug runs after it and must REPLACE that (not append),
      # tightening frame-ancestors to 'none' and adding default-src/script-src.
      conn = get(conn, ~p"/")
      [csp] = get_resp_header(conn, "content-security-policy")

      assert csp =~ "default-src 'self'"
      refute csp =~ "frame-ancestors 'self'"
    end

    test "documents the two scoped CSP relaxations: inline styles and broad img-src", %{
      conn: conn
    } do
      # closes CFG-003-T12
      # `style-src 'unsafe-inline'` is the LiveView colocated-<style> concession;
      # `img-src ... https:` lets remote images load. Both are the documented
      # relaxations — pin them so a tightening/loosening is a deliberate diff.
      conn = get(conn, ~p"/")
      [csp] = get_resp_header(conn, "content-security-policy")

      assert csp =~ "style-src 'self' 'unsafe-inline'"
      assert csp =~ "img-src 'self' data: https:"
      # The relaxations are scoped to styles/images only — scripts stay strict.
      refute csp =~ "script-src 'self' 'unsafe-inline'"
    end
  end
end
