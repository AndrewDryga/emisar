defmodule EmisarWeb.AdminGateTest do
  @moduledoc """
  The platform-admin gate on `/admin/live` (LiveDashboard) and the
  dev-only `/dev/*` mounts — both are pure router/endpoint gate behaviour
  for a security product, so they live together here.

  `/admin/live` rides `[:browser, :noindex, :require_authenticated_user,
  :require_admin]`: two independent gates (signed in AND `is_admin`), and
  `is_admin` is a global platform flag set out-of-band (no UI), distinct
  from per-account role. The `/dev/*` mounts are compiled out entirely
  unless `:dev_routes` is set (dev only), so in test they must 404.
  """
  use EmisarWeb.ConnCase, async: true

  alias Emisar.Repo

  # Read the compile-time flag in the module body (the macro can't run
  # inside a function) so the dev-routes-off assertion can check it.
  @dev_routes Application.compile_env(:emisar_web, :dev_routes)

  # `is_admin` has no production write path (set via console/migration
  # only), so the test grants it out-of-band, the same shape
  # require_sso_test uses for its account flag.
  defp make_admin(user), do: user |> Ecto.Changeset.change(is_admin: true) |> Repo.update!()

  describe "the /admin/live admin gate" do
    test "an is_admin user reaches the LiveDashboard", %{conn: conn} do
      {conn, user, _account} = register_and_log_in(conn)
      make_admin(user)

      conn = get(conn, "/admin/live")

      # LiveDashboard 302-redirects "/admin/live" to its first page
      # ("/admin/live/home"); a denied user would be sent to "/app"
      # instead, so reaching a /admin/live/* page is the pass signal.
      assert redirected_to(conn) =~ "/admin/live"
      refute redirected_to(conn) == "/app"
    end

    test "an authenticated non-admin is denied with a flash + redirect to /app", %{conn: conn} do
      # /T02
      {conn, _user, _account} = register_and_log_in(conn)

      conn = get(conn, "/admin/live")

      assert redirected_to(conn) == "/app"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Not authorized."
      assert conn.halted
    end

    test "an account owner who is not is_admin is still denied", %{conn: conn} do
      # register_and_log_in makes the user the account OWNER; platform admin
      # is independent of tenant role, so the owner is denied just the same.
      {conn, user, _account} = register_and_log_in(conn)
      refute user.is_admin

      conn = get(conn, "/admin/live")

      assert redirected_to(conn) == "/app"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Not authorized."
    end

    test "an anonymous user is bounced to sign-in before the admin gate", %{conn: conn} do
      # /T06
      conn = get(conn, "/admin/live")

      # :require_authenticated_user runs before :require_admin, so an
      # unauthenticated request lands on sign-in, never the "Not authorized."
      # path — the two gates are ordered and both required.
      assert redirected_to(conn) == ~p"/sign_in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "You must log in to access that page."
    end

    test "the admin mount rides the :noindex pipeline (platform observability isn't crawled)",
         %{conn: conn} do
      # /admin/live pipes through :noindex, which sets the conn assign the root
      # layout turns into `<meta name="robots" content="noindex,nofollow">`.
      # The assign is set before the dashboard 302s, so it's observable here.
      {conn, user, _account} = register_and_log_in(conn)
      make_admin(user)

      conn = get(conn, "/admin/live")

      assert conn.assigns[:noindex] == true
    end

    test "a session that asserts is_admin: true does NOT bypass the gate", %{conn: conn} do
      # The gate reads `current_user.is_admin`, which fetch_current_user loads
      # from the DB by the session token — a forged/extra `is_admin` session key
      # is never consulted, so a non-admin stays denied even after stuffing it in.
      {conn, user, _account} = register_and_log_in(conn)
      refute user.is_admin

      # Add the forged key to the EXISTING signed-in session (don't reset it —
      # that would drop the user_token and make this an anonymous request).
      conn = conn |> put_session(:is_admin, true) |> get("/admin/live")

      assert redirected_to(conn) == "/app"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Not authorized."
    end
  end

  describe "the is_admin flag" do
    test "defaults to false for a freshly registered user (closed by default)", %{conn: _conn} do
      {:ok, user} =
        Emisar.Users.register_user(%{
          email: "fresh-#{System.unique_integer([:positive])}@example.com",
          full_name: "Fresh User",
          password: "very-long-password-here"
        })

      assert user.is_admin == false
    end
  end

  describe "the dev-only routes" do
    test "the :dev_routes flag is off in the test env" do
      # The /dev mount is compiled in only under `:dev_routes` (dev.exs).
      # Confirm it's falsy here before asserting the routes are absent.
      refute @dev_routes
    end

    test "/dev/dashboard is not mounted — the branded 404, not a 403", %{conn: conn} do
      # /T02
      # Compiled out, so it matches no route and falls to the :browser
      # catch-all → the branded 404 page (NOT a 403 — the route doesn't
      # exist to be forbidden), exactly like any other unrouted path.
      conn = get(conn, "/dev/dashboard")
      assert html_response(conn, 404) =~ "Page not found"
    end

    test "/dev/mailbox is not mounted — the branded 404", %{conn: conn} do
      conn = get(conn, "/dev/mailbox")
      assert html_response(conn, 404) =~ "Page not found"
    end
  end
end
