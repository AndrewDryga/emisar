defmodule EmisarWeb.AdminGateTest do
  @moduledoc """
  The staff gate on `/admin` (the staff console) and `/ops/live` (LiveDashboard),
  and the dev-only `/dev/*` mounts — pure router/endpoint gate behaviour for a
  security product, so they live together here.

  Staff routes ride `[:staff_browser, :require_staff]`: the staff cookie is their
  whole session, and only a live staff session row named by it opens them. A
  workspace session, of any role, opens nothing. `:ensure_staff` re-decides on
  the socket at mount, before every event and patch, and when the session
  expires. The `/dev/*` mounts are compiled out entirely unless `:dev_routes` is
  set (dev only), so in test they must 404.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Admin, Repo}
  alias EmisarWeb.StaffAuth

  # Read the compile-time flag in the module body (the macro can't run
  # inside a function) so the dev-routes-off assertion can check it.
  @dev_routes Application.compile_env(:emisar_web, :dev_routes)

  # The socket half of the gate is driven directly against a disconnected
  # socket carrying the flash assign `put_flash/3` writes into.
  defp mount_socket, do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}

  describe "the staff gate" do
    test "a live staff session reaches the console", %{conn: conn} do
      staff = Fixtures.Admin.create_staff()
      {conn, _staff_session} = log_in_staff(conn, staff)

      assert {:ok, _live, html} = live(conn, ~p"/admin")
      assert html =~ "Emisar Admin"
      assert html =~ staff.email
    end

    test "a live staff session reaches the LiveDashboard over the staff socket", %{conn: conn} do
      {conn, _staff_session} = log_in_staff(conn)

      # LiveDashboard 302-redirects "/ops/live" to its first page; a denied
      # request goes to the staff sign-in instead.
      assert redirected_to(get(conn, "/ops/live")) =~ "/ops/live/"

      html = conn |> get("/ops/live/home") |> html_response(200)
      assert html =~ ~s(phx-socket="/admin/live")
    end

    test "the dashboard reuses the CSP nonce and enables Ecto Stats", %{conn: conn} do
      {conn, _staff_session} = log_in_staff(conn)

      conn = get(conn, "/ops/live/ecto_stats")
      html = html_response(conn, 200)
      [csp] = get_resp_header(conn, "content-security-policy")
      [_, nonce] = Regex.run(~r/'nonce-([^']+)'/, csp)

      assert csp =~ "font-src 'self' data:"
      refute csp =~ ~r/script-src [^;]*'unsafe-inline'/
      assert html =~ ~s(<script nonce="#{nonce}">)
      assert html =~ "Ecto Stats"
    end

    test "staff pages connect their LiveViews to the staff socket", %{conn: conn} do
      {conn, _staff_session} = log_in_staff(conn)

      html = conn |> get(~p"/admin") |> html_response(200)

      assert html =~ ~s(<meta name="live-socket-path" content="/admin/live">)
    end

    test "an anonymous request is sent to the staff sign-in", %{conn: conn} do
      account = Fixtures.Accounts.create_account()

      for path <- [~p"/admin", ~p"/admin/accounts/#{account.id}", "/ops/live"] do
        conn = get(conn, path)

        assert redirected_to(conn) == ~p"/admin/sign_in"
        assert conn.halted
      end
    end

    test "a workspace session token opens nothing, even inside the staff cookie", %{conn: conn} do
      # An owner's real workspace session: platform staff is independent of any
      # tenant role, and the staff gate only looks in the staff token table.
      {owner, account, _subject} = Fixtures.Subjects.owner_subject()
      token = Fixtures.Auth.create_session_token!(owner, :magic_link, DateTime.utc_now())

      for session <- [
            %{"sessions" => [{account.id, token}]},
            %{"user_token" => token},
            %{"staff_token" => token}
          ] do
        conn = conn |> put_staff_cookie(session) |> get(~p"/admin")

        assert redirected_to(conn) == ~p"/admin/sign_in"
      end
    end

    test "staff routes never read or write the workspace session cookie", %{conn: conn} do
      {conn, _staff_session} = log_in_staff(conn)

      for path <- [~p"/admin", ~p"/admin/sign_in", "/ops/live"] do
        conn = get(conn, path)

        refute Map.has_key?(conn.resp_cookies, "_emisar_web_key")
      end

      conn = get(build_conn(), ~p"/admin/sign_in")
      assert Map.has_key?(conn.resp_cookies, "_emisar_staff")
      refute Map.has_key?(conn.resp_cookies, "_emisar_web_key")
    end

    test "the staff store refuses a request that already holds a session", %{conn: conn} do
      conn = Phoenix.ConnTest.init_test_session(conn, %{"user_token" => "workspace"})

      assert_raise ArgumentError, ~r/before the staff session store/, fn ->
        StaffAuth.use_staff_session_cookie(conn, [])
      end
    end

    test "the staff cookie is HttpOnly, same-site and lives 12 hours", %{conn: conn} do
      conn = get(conn, ~p"/admin/sign_in")
      cookie = conn.resp_cookies["_emisar_staff"]

      assert cookie.http_only
      assert cookie.same_site == "Lax"
      assert cookie.max_age == 12 * 60 * 60
      refute cookie[:secure]

      Emisar.Config.put_override(:emisar_web, :force_secure_cookies, true)
      cookie = get(build_conn(), ~p"/admin/sign_in").resp_cookies["_emisar_staff"]
      assert cookie.secure
    end

    test "an expired session sends the browser to sign in again", %{conn: conn} do
      staff = Fixtures.Admin.create_staff()
      expired = DateTime.add(DateTime.utc_now(), -1)
      {raw, _session} = Fixtures.Admin.create_staff_session(staff, expires_at: expired)

      conn = conn |> put_staff_cookie(%{"staff_token" => raw}) |> get(~p"/admin")

      assert redirected_to(conn) == ~p"/admin/sign_in"
      assert get_session(conn, :staff_token) == nil

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Your staff session has ended. Sign in again."
    end

    test "a session whose staff login was reset or removed opens nothing", %{conn: conn} do
      reset = Fixtures.Admin.create_staff()
      {reset_conn, _session} = log_in_staff(conn, reset)
      assert {:ok, _staff, _secret} = Admin.reset_staff(reset.email)

      assert redirected_to(get(reset_conn, ~p"/admin")) == ~p"/admin/sign_in"

      removed = Fixtures.Admin.create_staff()
      {removed_conn, _session} = log_in_staff(build_conn(), removed)
      assert Admin.remove_staff(removed.email) == :ok

      assert redirected_to(get(removed_conn, "/ops/live")) == ~p"/admin/sign_in"
    end

    test "the staff pages ride the :noindex pipeline", %{conn: conn} do
      {conn, _staff_session} = log_in_staff(conn)

      assert get(conn, ~p"/admin").assigns[:noindex] == true
      assert get(conn, "/ops/live").assigns[:noindex] == true
      assert get(build_conn(), ~p"/admin/sign_in").assigns[:noindex] == true
    end
  end

  describe "the staff socket gate" do
    test "each LiveView socket reads only its own realm's cookie" do
      sockets = EmisarWeb.Endpoint.__sockets__()
      assert sockets |> Enum.map(&elem(&1, 0)) |> Enum.sort() == ["/admin/live", "/live"]

      for {path, _module, opts} <- sockets, transport <- [:websocket, :longpoll] do
        {:session, session} =
          opts
          |> Keyword.fetch!(transport)
          |> Keyword.fetch!(:connect_info)
          |> List.keyfind(:session, 0)

        expected = if path == "/admin/live", do: "_emisar_staff", else: "_emisar_web_key"

        assert session[:key] == expected, "#{path} over #{transport} reads #{session[:key]}"
      end
    end

    test "sign-out, a box reset and a removal each disconnect the session's sockets", %{
      conn: conn
    } do
      signed_out = Fixtures.Admin.create_staff()
      {raw, _session} = Fixtures.Admin.create_staff_session(signed_out)
      topic = Admin.staff_session_socket_topic(raw)
      EmisarWeb.Endpoint.subscribe(topic)

      conn |> put_staff_cookie(%{"staff_token" => raw}) |> delete(~p"/admin/sign_out")
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}

      for revoke <- [&Admin.reset_staff/1, &Admin.remove_staff/1] do
        staff = Fixtures.Admin.create_staff()
        {raw, _session} = Fixtures.Admin.create_staff_session(staff)
        topic = Admin.staff_session_socket_topic(raw)
        EmisarWeb.Endpoint.subscribe(topic)

        revoke.(staff.email)

        assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
      end
    end

    test "mounts a live staff session" do
      staff = Fixtures.Admin.create_staff()
      {raw, staff_session} = Fixtures.Admin.create_staff_session(staff)

      assert {:cont, socket} =
               StaffAuth.on_mount(:ensure_staff, %{}, %{"staff_token" => raw}, mount_socket())

      assert socket.assigns.staff_session.id == staff_session.id
      assert socket.assigns.staff_session.staff.id == staff.id
    end

    test "refuses a token that names no live staff session" do
      {raw, _session} = Fixtures.Admin.create_staff_session(Fixtures.Admin.create_staff())
      assert Admin.delete_staff_session(raw) == :ok

      for session <- [%{"staff_token" => raw}, %{"staff_token" => "forged"}] do
        assert {:halt, socket} = StaffAuth.on_mount(:ensure_staff, %{}, session, mount_socket())
        assert {:redirect, %{to: "/admin/sign_in"}} = socket.redirected
        assert socket.assigns.flash["error"] == "Your staff session has ended. Sign in again."
      end

      assert {:halt, socket} = StaffAuth.on_mount(:ensure_staff, %{}, %{}, mount_socket())
      assert {:redirect, %{to: "/admin/sign_in"}} = socket.redirected
      assert socket.assigns.flash == %{}
    end

    test "an open console re-checks the session before every event", %{conn: conn} do
      {conn, staff_session} = log_in_staff(conn)
      {:ok, live, _html} = live(conn, ~p"/admin")

      Repo.delete!(staff_session)
      render_change(form(live, "#account-search"), %{"query" => "acme"})

      flash = assert_redirect(live, ~p"/admin/sign_in")
      assert flash["error"] == "Your staff session has ended. Sign in again."
    end

    test "an open dashboard re-checks the session before every page change", %{conn: conn} do
      # LiveDashboard moves between pages by patching, with no event to hook.
      {conn, staff_session} = log_in_staff(conn)
      {:ok, live, _html} = live(conn, "/ops/live/home")

      Repo.delete!(staff_session)
      render_patch(live, "/ops/live/ecto_stats")

      flash = assert_redirect(live, ~p"/admin/sign_in")
      assert flash["error"] == "Your staff session has ended. Sign in again."
    end

    test "an open console leaves when its session expires", %{conn: conn} do
      {conn, staff_session} = log_in_staff(conn)
      {:ok, live, _html} = live(conn, ~p"/admin")

      send(live.pid, {:staff_session_expired, staff_session.id})

      flash = assert_redirect(live, ~p"/admin/sign_in")
      assert flash["error"] == "Your staff session has ended. Sign in again."
    end
  end

  describe "the dev-only routes" do
    test "the :dev_routes flag is off in the test env" do
      # The /dev mount is compiled in only under `:dev_routes` (dev.exs).
      # Confirm it's falsy here before asserting the routes are absent.
      refute @dev_routes
    end

    test "/dev/dashboard is not mounted — the branded 404, not a 403", %{conn: conn} do
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
