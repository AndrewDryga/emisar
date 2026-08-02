defmodule EmisarWeb.ErrorHTMLTest do
  use EmisarWeb.ConnCase, async: true
  import Phoenix.Template, only: [render_to_string: 4]

  describe "404" do
    test "renders a branded page via the endpoint when a route is missing", %{conn: conn} do
      conn = get(conn, "/this-route-does-not-exist")

      assert html_response(conn, 404) =~ "Page not found"
      assert html_response(conn, 404) =~ "Error 404"
      assert html_response(conn, 404) =~ "Back to home"
      assert html_response(conn, 404) =~ "Open dashboard"
    end

    test "carries noindex so 404s aren't crawled into the SERP" do
      html = render_to_string(EmisarWeb.ErrorHTML, "404", "html", %{})
      assert html =~ ~s(<meta name="robots" content="noindex, nofollow")
    end

    test "uses the self-hosted application stylesheet, never a third-party font CDN" do
      html = render_to_string(EmisarWeb.ErrorHTML, "404", "html", %{})

      assert html =~ ~s(href="/assets/app.css")
      refute html =~ "rsms.me"
    end
  end

  describe "500" do
    test "renders a branded page with the support email exposed" do
      html = render_to_string(EmisarWeb.ErrorHTML, "500", "html", %{})
      assert html =~ "Something broke on our side"
      assert html =~ "Error 500"
      assert html =~ "support@emisar.dev"
    end

    test "leaks no stacktrace or struct detail to the visitor" do
      # The renderer takes `_assigns`, so even a caller that passed a reason /
      # stacktrace can't surface one — the prod 500 (debug_errors off) shows the
      # bare branded copy only, never internal detail.
      html = render_to_string(EmisarWeb.ErrorHTML, "500", "html", %{})

      refute html =~ "Elixir."
      refute html =~ "stacktrace"
      refute html =~ "%{"
    end
  end

  describe "403" do
    test "renders spoken recovery copy, never the raw Forbidden" do
      html = render_to_string(EmisarWeb.ErrorHTML, "403", "html", %{})

      assert html =~ "Error 403"
      assert html =~ "verify that request"
      assert html =~ "Go back, refresh the page, and try again."
      refute html =~ "Forbidden"
    end

    test "a stale-session CSRF POST comes back as the spoken 403 page", %{conn: conn} do
      # The common way an operator meets a 403: a sign-in form left open until
      # the session (and its CSRF token) expired, then submitted.
      conn = Plug.Conn.put_private(conn, :plug_skip_csrf_protection, false)

      {403, _headers, body} =
        assert_error_sent(403, fn -> post(conn, ~p"/sign_in/magic/start", %{}) end)

      assert body =~ "verify that request"
      refute body =~ "Forbidden"
    end
  end

  describe "other status codes" do
    test "renders the generic page with the Phoenix status message" do
      html = render_to_string(EmisarWeb.ErrorHTML, "400", "html", %{})
      assert html =~ "Bad Request"
      assert html =~ "Error 400"
    end

    test "an unknown status code still renders a branded page via the catch-all" do
      # A status with no explicit clause (e.g. 418) falls to `render(template, _)`,
      # which derives the number + the standard message ("I'm a teapot") rather
      # than emitting a blank/raw 418.
      html = render_to_string(EmisarWeb.ErrorHTML, "418", "html", %{})

      assert html =~ "Error 418"
      assert html =~ "teapot"
      assert html =~ "Back to home"
    end
  end
end
