defmodule EmisarWeb.AdminGateTest do
  @moduledoc """
  The platform-admin gate on `/admin/live` (LiveDashboard) and the
  dev-only `/dev/*` mounts — both are pure router/endpoint gate behaviour
  for a security product, so they live together here.

  `/admin/live` rides `[:browser, :noindex, :require_authenticated_user,
  :require_admin]`: three independent gates (signed in AND `is_admin` AND a
  second factor this session proved against the CURRENT enrollment), plus the
  `:ensure_admin` on_mount that re-decides all three on the socket. `is_admin` is
  a global platform flag set out-of-band (no UI), distinct from per-account role.
  The `/dev/*` mounts are compiled out entirely unless `:dev_routes` is set (dev
  only), so in test they must 404.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Auth, Repo}
  alias EmisarWeb.UserAuth

  # Read the compile-time flag in the module body (the macro can't run
  # inside a function) so the dev-routes-off assertion can check it.
  @dev_routes Application.compile_env(:emisar_web, :dev_routes)

  # `is_admin` has no production write path (set via console/migration
  # only), so the test grants it out-of-band, the same shape
  # require_sso_test uses for its account flag.
  defp make_admin(user), do: user |> Ecto.Changeset.change(is_admin: true) |> Repo.update!()

  # A real signed-in session stamped with the moment it proved the second factor
  # — what an admin holds after clearing the MFA challenge at sign-in. Call it
  # AFTER enrolling, so the proof lands past `mfa_enabled_at` the way a real
  # challenge does.
  defp complete_mfa_challenge(conn, user) do
    token = Fixtures.Auth.create_session_token!(user, :magic_link, DateTime.utc_now())
    put_session(conn, :user_token, token)
  end

  # The socket half of the gate can't be reached through a request (the plug
  # denies the dead render first), so its tests drive `on_mount` directly against
  # a socket carrying the flash assign `put_flash/3` writes into.
  defp mount_socket, do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}

  describe "the /admin/live admin gate" do
    test "an admin who verified a second factor this session reaches the LiveDashboard", %{
      conn: conn
    } do
      {conn, user, account} = register_and_log_in(conn)
      Fixtures.Users.enable_mfa!(Auth.generate_mfa_secret(), owner_subject(user, account))
      make_admin(user)

      conn = conn |> complete_mfa_challenge(user) |> get("/admin/live")

      # LiveDashboard 302-redirects "/admin/live" to its first page
      # ("/admin/live/home"); a denied user would be sent to "/app",
      # "/app/mfa_setup", or "/sign_in" instead, so reaching a /admin/live/*
      # page is the pass signal.
      assert redirected_to(conn) =~ "/admin/live"
    end

    test "an admin who has not enrolled MFA is sent to set it up", %{conn: conn} do
      {conn, user, _account} = register_and_log_in(conn)
      make_admin(user)

      conn = get(conn, "/admin/live")

      assert redirected_to(conn) == ~p"/app/mfa_setup"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Admin access requires two-factor authentication. Set it up to continue."
    end

    test "an admin whose session never proved the second factor is signed out", %{conn: conn} do
      # Enrolling while already signed in leaves this session with no
      # `mfa_verified_at`, and that column is fixed at mint — the only way to
      # elevate is a fresh sign-in, so the gate ends the session rather than
      # leaving the admin on a dead end.
      {conn, user, account} = register_and_log_in(conn)
      Fixtures.Users.enable_mfa!(Auth.generate_mfa_secret(), owner_subject(user, account))
      make_admin(user)

      conn = get(conn, "/admin/live")

      assert redirected_to(conn) == ~p"/sign_in"
      assert get_session(conn, :user_token) == nil

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Admin access requires two-factor authentication. Sign in again to continue."
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
               "You must sign in to access that page."
    end

    test "the admin mount rides the :noindex pipeline (platform observability isn't crawled)",
         %{conn: conn} do
      # /admin/live pipes through :noindex, which sets the conn assign the root
      # layout turns into `<meta name="robots" content="noindex,nofollow">`.
      # The assign is set before the dashboard 302s, so it's observable here.
      {conn, user, account} = register_and_log_in(conn)
      Fixtures.Users.enable_mfa!(Auth.generate_mfa_secret(), owner_subject(user, account))
      make_admin(user)

      conn = conn |> complete_mfa_challenge(user) |> get("/admin/live")

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

    test "a session that asserts mfa_verified_at does NOT fake a verified second factor", %{
      conn: conn
    } do
      # The proof is read off the session row behind the cookie, so an enrolled
      # admin whose session never proved a factor stays denied even after
      # stuffing the claim into the session.
      {conn, user, account} = register_and_log_in(conn)
      Fixtures.Users.enable_mfa!(Auth.generate_mfa_secret(), owner_subject(user, account))
      make_admin(user)

      conn = conn |> put_session(:mfa_verified_at, DateTime.utc_now()) |> get("/admin/live")

      assert redirected_to(conn) == ~p"/sign_in"
    end

    test "a proof taken against a replaced enrollment stops opening the door", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      subject = owner_subject(user, account)

      {_user, [recovery_code | _]} =
        Fixtures.Users.enable_mfa!(Auth.generate_mfa_secret(), subject)

      make_admin(user)

      conn = complete_mfa_challenge(conn, user)
      session_token = get_session(conn, :user_token)
      assert redirected_to(get(conn, "/admin/live")) =~ "/admin/live"

      {:ok, _disabled} = Auth.disable_mfa(recovery_code, subject)
      Fixtures.Users.enable_mfa!(Auth.generate_mfa_secret(), subject)

      # Self-service disable deliberately keeps sessions alive, so this cookie is
      # still a valid credential — the ONLY thing standing between it and the
      # staff surface is `mfa_verified_at` now predating `mfa_enabled_at`.
      assert {:ok, _user, _session} = Auth.fetch_user_and_token_by_session_token(session_token)

      conn = get(conn, "/admin/live")

      assert redirected_to(conn) == ~p"/sign_in"
      assert get_session(conn, :user_token) == nil

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Admin access requires two-factor authentication. Sign in again to continue."
    end
  end

  describe "the /admin/live socket gate" do
    test "an admin who verified a second factor this session mounts" do
      {user, _account, subject} = Fixtures.Subjects.owner_subject()
      Fixtures.Users.enable_mfa!(Auth.generate_mfa_secret(), subject)
      make_admin(user)
      token = Fixtures.Auth.create_session_token!(user, :magic_link, DateTime.utc_now())

      assert {:cont, socket} =
               UserAuth.on_mount(:ensure_admin, %{}, %{"user_token" => token}, mount_socket())

      assert socket.assigns.current_user.id == user.id
    end

    test "a proof taken against a replaced enrollment no longer mounts" do
      # The socket half of the binding. A mount cannot clear the plug session, so
      # it only REFUSES and sends the admin back to /app; the plug owns the
      # forced step-up on their next full navigation.
      {user, _account, subject} = Fixtures.Subjects.owner_subject()
      {enrolled_user, _codes} = Fixtures.Users.enable_mfa!(Auth.generate_mfa_secret(), subject)
      make_admin(user)

      stale_proof_at = DateTime.add(enrolled_user.mfa_enabled_at, -1, :second)
      token = Fixtures.Auth.create_session_token!(user, :magic_link, stale_proof_at)

      assert {:halt, socket} =
               UserAuth.on_mount(:ensure_admin, %{}, %{"user_token" => token}, mount_socket())

      assert {:redirect, %{to: to}} = socket.redirected
      assert to == ~p"/app"

      assert Phoenix.Flash.get(socket.assigns.flash, :error) ==
               "Admin access requires two-factor authentication. Sign in again to continue."
    end

    test "an admin who turned MFA off mid-session is halted to MFA setup" do
      # A LiveView session stays verifiable for 14 days, so the socket must
      # re-decide: this token proved a factor at sign-in, but the enrollment
      # behind it is gone, and only the on_mount sees that on a reconnect.
      user = Fixtures.Users.create_user()
      make_admin(user)
      token = Fixtures.Auth.create_session_token!(user, :magic_link, DateTime.utc_now())

      assert {:halt, socket} =
               UserAuth.on_mount(:ensure_admin, %{}, %{"user_token" => token}, mount_socket())

      assert {:redirect, %{to: to}} = socket.redirected
      assert to == ~p"/app/mfa_setup"

      assert Phoenix.Flash.get(socket.assigns.flash, :error) ==
               "Admin access requires two-factor authentication. Set it up to continue."
    end

    test "a non-admin is halted to /app" do
      user = Fixtures.Users.create_user()
      token = Fixtures.Auth.create_session_token!(user, :magic_link, DateTime.utc_now())

      assert {:halt, socket} =
               UserAuth.on_mount(:ensure_admin, %{}, %{"user_token" => token}, mount_socket())

      assert {:redirect, %{to: to}} = socket.redirected
      assert to == ~p"/app"
      assert Phoenix.Flash.get(socket.assigns.flash, :error) == "Not authorized."
    end
  end

  describe "the is_admin flag" do
    test "defaults to false for a freshly registered user (closed by default)", %{conn: _conn} do
      {:ok, user} =
        Emisar.Users.register_user(%{
          email: "fresh-#{System.unique_integer([:positive])}@example.com",
          full_name: "Fresh User"
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
