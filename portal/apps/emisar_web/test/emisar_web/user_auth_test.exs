defmodule EmisarWeb.UserAuthTest do
  use EmisarWeb.ConnCase, async: true

  alias EmisarWeb.UserAuth

  @remember_me_cookie "_emisar_user_remember_me"

  # Session provenance for an unauthenticated request — the miss/anonymous
  # default the Subject build reads from. Mirrors `UserAuth`'s private @no_auth.
  @no_auth %{auth_method: nil, mfa: nil, user_identity_id: nil}

  setup %{conn: conn} do
    # secret_key_base is needed to sign the remember-me cookie; a bare test
    # conn doesn't carry it until it's been through the endpoint.
    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Map.put(:secret_key_base, EmisarWeb.Endpoint.config(:secret_key_base))

    %{conn: conn}
  end

  describe "on_mount :mount_current_user" do
    test "with no token, assigns a nil user + @no_auth provenance and never halts" do
      # the bundle hook is NOT a
      # gate: a signed-out mount continues with `current_user: nil` and the
      # anonymous `@no_auth` provenance, so a public/signed-out LiveView mounts
      # cleanly (the actual gating is :ensure_authenticated, AUTH-021).
      socket = %Phoenix.LiveView.Socket{}

      assert {:cont, socket} = UserAuth.on_mount(:mount_current_user, %{}, %{}, socket)
      assert socket.assigns.current_user == nil
      assert socket.assigns.current_auth == @no_auth
    end

    test "with an undecodable/forged token, treats it as a miss — nil user, no raise" do
      # a stale or tampered `user_token` resolves to no live
      # session (the `with` falls to its else clause); the hook swallows it into the
      # same anonymous default rather than crashing the mount.
      socket = %Phoenix.LiveView.Socket{}

      assert {:cont, socket} =
               UserAuth.on_mount(
                 :mount_current_user,
                 %{},
                 %{"user_token" => "!!!not-a-real-token!!!"},
                 socket
               )

      assert socket.assigns.current_user == nil
      assert socket.assigns.current_auth == @no_auth
    end
  end

  describe "on_mount :assign_app_bundle" do
    test "is a pure bundle flag — always {:cont} with app_js? true, no auth dependence" do
      # the hook that flags "this render needs the full app.js"
      # is NOT a gate and reads no session/user: a signed-out mount (empty session)
      # gets the exact same `{:cont}` + `app_js?: true` as a signed-in one. Every
      # LiveView render carries the flag up to root.html.heex; only controller-
      # rendered marketing pages (which never run this hook) get the lean bundle.
      socket = %Phoenix.LiveView.Socket{}

      assert {:cont, signed_out} = UserAuth.on_mount(:assign_app_bundle, %{}, %{}, socket)
      assert signed_out.assigns.app_js? == true

      assert {:cont, with_session} =
               UserAuth.on_mount(:assign_app_bundle, %{}, %{"user_token" => "anything"}, socket)

      assert with_session.assigns.app_js? == true
    end
  end

  describe "on_mount :assign_app_bundle drives the root-layout JS bundle" do
    test "a LiveView page loads the full app.js bundle (LiveSocket + hooks)", %{conn: conn} do
      # `:assign_app_bundle` (attached to every LiveView via
      # EmisarWeb.live_view/0) sets `@app_js?`, which the root layout reads to load the
      # full `/assets/app.js`. The dead render of an authed LV route carries that
      # script tag — the LiveSocket + hooks the interactive page needs.
      {conn, _user, account} = register_and_log_in(conn)

      html = conn |> get(~p"/app/#{account}") |> html_response(200)

      assert html =~ ~s|src="/assets/app.js"|
      refute html =~ ~s|src="/assets/marketing.js"|
    end

    test "a controller-rendered marketing page loads only the lean marketing.js", %{conn: conn} do
      # a marketing page is a plain controller render that never
      # runs the LiveView on_mount, so `@app_js?` is absent and the root layout falls
      # to the lean `/assets/marketing.js` — no LiveSocket weight on a static page.
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s|src="/assets/marketing.js"|
      refute html =~ ~s|src="/assets/app.js"|
    end
  end

  describe "redirect_if_user_is_authenticated guards the whole signed-out auth surface" do
    test "an already-signed-in visitor is bounced off EVERY guarded auth page to /app", %{
      conn: conn
    } do
      # the gate guards the full signed-out
      # auth surface, not just /sign_in: sign_up, the magic-link step, and the
      # branded per-account page all live under :redirect_if_user_is_authenticated,
      # so a signed-in user GETting any of them is redirected to the app before the
      # LiveView mounts.
      {conn, _user, account} = register_and_log_in(conn)

      for path <- [
            ~p"/sign_up",
            ~p"/sign_in",
            ~p"/sign_in/magic",
            ~p"/app/#{account}/sign_in"
          ] do
        assert redirected_to(get(conn, path)) == ~p"/app"
      end
    end

    test "the auth POST endpoints bounce a signed-in visitor too", %{conn: conn} do
      # (POST half) — the magic-link start POST is in the same
      # guarded scope, so a signed-in user can't re-drive a sign-in request; the
      # gate halts before the controller runs.
      {conn, user, _account} = register_and_log_in(conn)

      conn = post(conn, ~p"/sign_in/magic/start", user: %{"email" => user.email})

      assert redirected_to(conn) == ~p"/app"
    end
  end

  describe "sign-in form CSRF posture" do
    test "the sign-in form carries a CSRF token for its POST to the magic-link start",
         %{conn: conn} do
      # the email form posts over the CSRF-protected
      # :browser pipeline (`protect_from_forgery`). Because it renders with an
      # `action`+`method=post`, `<.form>` emits the hidden `_csrf_token` input, so
      # a legitimate browser submit is accepted and a forged cross-site one isn't.
      {:ok, _lv, html} = live(conn, ~p"/sign_in")

      assert html =~ "_csrf_token"
      assert html =~ ~s|action="/sign_in/magic/start"|
    end
  end

  describe "require_authenticated_user return_to" do
    test "a signed-out GET stores return_to but a signed-out POST does not", %{conn: _conn} do
      # the plug remembers where to send the user back ONLY
      # for a GET (a navigable destination). A POST to a protected path while
      # signed-out still redirects to /sign_in, but stores no `:user_return_to` —
      # re-running the POST blindly after login would be wrong, so there's nothing
      # to return to.
      get_conn = build_conn() |> Plug.Test.init_test_session(%{}) |> get(~p"/app")
      assert redirected_to(get_conn) == ~p"/sign_in"
      assert get_session(get_conn, :user_return_to) == ~p"/app"

      post_conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> post(~p"/app/accounts/switch", account_id: Ecto.UUID.generate())

      assert redirected_to(post_conn) == ~p"/sign_in"
      refute get_session(post_conn, :user_return_to)
    end
  end

  describe "log_in_user/3" do
    test "remember_me writes a persistent signed cookie alongside the session token", %{
      conn: conn
    } do
      # `remember_me: "true"` writes the persistent token
      # cookie (alongside the session token) with the documented 60-DAY max-age, so
      # the operator stays signed in across browser restarts for exactly that window.
      conn =
        UserAuth.log_in_user(
          conn,
          Emisar.Fixtures.user_fixture(),
          :magic_link,
          false,
          %{"remember_me" => "true"}
        )

      assert Plug.Conn.get_session(conn, :user_token)
      assert %{max_age: max_age, value: value} = conn.resp_cookies[@remember_me_cookie]
      assert is_binary(value)
      # 60 days, matching UserAuth.remember_me_options/0.
      assert max_age == 60 * 60 * 24 * 60
    end

    test "without remember_me, only the session token is set — no persistent cookie", %{
      conn: conn
    } do
      conn = UserAuth.log_in_user(conn, Emisar.Fixtures.user_fixture(), :magic_link, false)

      assert Plug.Conn.get_session(conn, :user_token)
      refute conn.resp_cookies[@remember_me_cookie]
    end
  end
end
