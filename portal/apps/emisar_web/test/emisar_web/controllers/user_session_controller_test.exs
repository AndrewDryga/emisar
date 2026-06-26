defmodule EmisarWeb.UserSessionControllerTest do
  use EmisarWeb.ConnCase, async: true

  alias Emisar.{Accounts, Auth, Repo, Users}
  alias Emisar.Audit.Event

  describe "POST /sign_in (password verify security)" do
    test "an unknown email gets the SAME generic denial as a wrong password (no enumeration)",
         %{conn: conn} do
      # an attacker probing for valid emails must not be
      # able to tell "no such user" from "wrong password": identical flash,
      # identical redirect, no :email-exists oracle.
      {_logged_in, user, _account} = register_and_log_in(conn)

      wrong_password =
        post(build_conn(), ~p"/sign_in",
          user: %{"email" => user.email, "password" => "definitely-not-the-password"}
        )

      unknown_email =
        post(build_conn(), ~p"/sign_in",
          user: %{
            "email" => "nobody-#{System.unique_integer([:positive])}@example.com",
            "password" => "definitely-not-the-password"
          }
        )

      assert redirected_to(wrong_password) == ~p"/sign_in"
      assert redirected_to(unknown_email) == ~p"/sign_in"

      # Same deliberately-vague copy on both paths, so the response is identical.
      assert Phoenix.Flash.get(wrong_password.assigns.flash, :error) ==
               "That email and password don't match anything."

      assert Phoenix.Flash.get(unknown_email.assigns.flash, :error) ==
               Phoenix.Flash.get(wrong_password.assigns.flash, :error)
    end

    test "an empty password is rejected by the byte-size guard with no bcrypt and a generic deny",
         %{conn: conn} do
      # "" is still a binary, so it reaches the password
      # check, but `User.valid_password?/2`'s `byte_size(password) > 0` guard
      # routes it to `Bcrypt.no_user_verify/0` (constant-time, never the user's
      # hash). The operator-visible result is the same generic denial, never a
      # success, and the session stays signed out.
      {_logged_in, user, _account} = register_and_log_in(conn)

      conn =
        post(build_conn(), ~p"/sign_in", user: %{"email" => user.email, "password" => ""})

      assert redirected_to(conn) == ~p"/sign_in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "That email and password don't match anything."

      refute get_session(conn, :user_token)
    end

    test "a failed sign-in slices an over-long email to 160 chars in the re-prefill flash",
         %{conn: _conn} do
      # on a failed attempt the typed email is stashed in an
      # `:email` flash to pre-fill the form, but it's `String.slice(_, 0, 160)`'d
      # first so a pathological 300-char value can't bloat the session/flash. Same
      # generic denial as any wrong credential.
      long_local = String.duplicate("a", 300)
      long_email = "#{long_local}@example.com"

      conn =
        post(build_conn(), ~p"/sign_in",
          user: %{"email" => long_email, "password" => "definitely-not-the-password"}
        )

      assert redirected_to(conn) == ~p"/sign_in"
      assert String.length(Phoenix.Flash.get(conn.assigns.flash, :email)) == 160
    end

    test "the user record vanishing between password and MFA aborts to the expired bounce",
         %{conn: conn} do
      # the password step stashes a pending-MFA marker keyed by
      # user id; if that user is soft-deleted before the code is entered,
      # `do_finish_mfa`'s `fetch_user_by_id` returns `:not_found` and the controller
      # clears the marker and bounces to /sign_in with the expired message rather
      # than signing in a tombstoned account.
      password = "long-mfa-password-xyz"

      {:ok, user} =
        Users.register_user(%{
          email: "vanish-#{System.unique_integer([:positive])}@example.com",
          full_name: "Vanishing User",
          password: password
        })

      user = Emisar.Fixtures.confirm_user(user)

      {:ok, account} =
        Emisar.Accounts.create_account_with_owner(
          %{name: "Vanish Co", slug: Emisar.Accounts.suggest_unique_slug("Vanish Co")},
          user
        )

      secret = Auth.generate_mfa_secret()
      {_user, _codes} = Emisar.Fixtures.enable_mfa!(secret, owner_subject(user, account))

      # Password step → pending-MFA marker set, redirect to the challenge.
      conn = post(conn, ~p"/sign_in", user: %{"email" => user.email, "password" => password})
      assert redirected_to(conn) == ~p"/sign_in/mfa"

      # The user disappears before the second factor is entered.
      {:ok, _} = user |> Users.User.Changeset.delete() |> Repo.update()

      otp = NimbleTOTP.verification_code(secret)
      conn = conn |> recycle() |> post(~p"/sign_in", user: %{"otp" => otp})

      assert redirected_to(conn) == ~p"/sign_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "sign-in attempt expired"
      refute get_session(conn, :user_token)
    end

    test "a whitelisted return_to lands the member on that team after sign-in", %{conn: conn} do
      # a sign-in begun on a team's branded page posts a
      # `user[return_to]=/app/<slug>`; `ReturnTo.app_path` whitelists it to the bare
      # local landing, the controller stashes it as `:user_return_to`, and
      # `log_in_user` honors it over the default `/app`. The member IS in that team,
      # so they land on its slug, not their stale default.
      {_logged_in, user, account} = register_and_log_in(conn)

      conn =
        build_conn()
        |> post(~p"/sign_in",
          user: %{
            "email" => user.email,
            "password" => "very-long-password-here",
            "return_to" => "/app/#{account.slug}"
          }
        )

      assert redirected_to(conn) == ~p"/app/#{account}"
      assert get_session(conn, :user_token)
    end

    test "a user suspended in every account can finalize sign-in but is logged out downstream",
         %{conn: conn} do
      # password verify is identity, not membership: a
      # suspended-everywhere user still passes `fetch_user_by_email_and_password`
      # and the controller signs them in (a token is minted, they're redirected to
      # /app). The lock-out is enforced one layer down — the very next /app request
      # runs `require_authenticated_user` → `assign_current_account`, sees every
      # membership suspended, and force-logs-out with the suspension flash.
      {_logged_in, user, account} = register_and_log_in(conn)

      {1, _} =
        Accounts.Membership.Query.all()
        |> Accounts.Membership.Query.by_account_and_user(account.id, user.id)
        |> Repo.update_all(set: [disabled_at: DateTime.utc_now()])

      signed_in =
        build_conn()
        |> post(~p"/sign_in",
          user: %{"email" => user.email, "password" => "very-long-password-here"}
        )

      # Sign-in itself proceeds — credentials are valid, a session exists.
      assert redirected_to(signed_in) == ~p"/app"
      assert get_session(signed_in, :user_token)

      # …but the first authenticated request bounces them: forced logout, no token.
      bounced = signed_in |> recycle() |> get(~p"/app")
      assert redirected_to(bounced) == ~p"/sign_in"
      assert Phoenix.Flash.get(bounced.assigns.flash, :error) =~ "suspended"
      refute get_session(bounced, :user_token)
    end

    test "a successful sign-in renews the session id and drops any pre-login session data",
         %{conn: conn} do
      # session-fixation defence: `log_in_user` calls
      # `configure_session(renew: true)` + `clear_session`, so a value an
      # attacker planted in the pre-auth session can't survive into the
      # authenticated session, and a fresh token is what authenticates.
      {_logged_in, user, _account} = register_and_log_in(conn)

      conn =
        build_conn()
        |> init_test_session(%{})
        |> put_session(:planted_before_login, "attacker-value")
        |> post(~p"/sign_in",
          user: %{"email" => user.email, "password" => "very-long-password-here"}
        )

      assert redirected_to(conn) == ~p"/app"
      # The pre-login session was cleared on renewal — the planted key is gone…
      refute get_session(conn, :planted_before_login)
      # …and a real session token now authenticates the renewed session.
      assert token = get_session(conn, :user_token)
      assert {:ok, signed_in_user, _auth} = Auth.fetch_user_and_token_by_session_token(token)
      assert signed_in_user.id == user.id
    end
  end

  describe "split-code magic link" do
    # Drive the real request, then pull token_id + the 6-digit secret out of the
    # email. The returned conn carries the signed nonce cookie (via recycle), so a
    # follow-up confirm/code request is "the same browser" that requested.
    defp request_magic_link(conn, email) do
      conn = post(conn, ~p"/sign_in/magic/start", %{"user" => %{"email" => email}})
      assert_received {:email, sent}
      [_, token_id, secret] = Regex.run(~r"/sign_in/magic/([^/]+)/(\d{6})", sent.text_body)
      {recycle(conn), token_id, secret}
    end

    test "POST /start sets the nonce cookie and lands on the check-email page", %{conn: conn} do
      user = Emisar.Fixtures.user_fixture()
      conn = post(conn, ~p"/sign_in/magic/start", %{"user" => %{"email" => user.email}})

      assert redirected_to(conn) == ~p"/sign_in/magic?sent=1"
      assert conn.resp_cookies["emisar_magic"]
    end

    test "the email link signs in from the originating browser", %{conn: conn} do
      user = Emisar.Fixtures.user_fixture()
      {conn, token_id, secret} = request_magic_link(conn, user.email)

      conn = get(conn, ~p"/sign_in/magic/#{token_id}/#{secret}")

      assert token = get_session(conn, :user_token)
      assert {:ok, signed_in, _} = Auth.fetch_user_and_token_by_session_token(token)
      assert signed_in.id == user.id
    end

    test "the typed 6-digit code signs in from the browser holding the nonce", %{conn: conn} do
      user = Emisar.Fixtures.user_fixture()
      {conn, _token_id, secret} = request_magic_link(conn, user.email)

      conn = post(conn, ~p"/sign_in/magic/code", %{"code" => secret})

      assert token = get_session(conn, :user_token)
      assert {:ok, signed_in, _} = Auth.fetch_user_and_token_by_session_token(token)
      assert signed_in.id == user.id
    end

    test "the link WITHOUT the requesting browser's cookie can't sign in (anti-hijack)",
         %{conn: conn} do
      user = Emisar.Fixtures.user_fixture()
      {_conn, token_id, secret} = request_magic_link(conn, user.email)

      # A DIFFERENT browser (fresh conn, no nonce cookie) clicking the intercepted
      # link → no sign-in. The core web-level hijack guarantee.
      conn = get(build_conn(), ~p"/sign_in/magic/#{token_id}/#{secret}")

      assert redirected_to(conn) == ~p"/sign_in/magic"
      refute get_session(conn, :user_token)
    end

    test "a wrong secret is uniformly invalid (no oracle)", %{conn: conn} do
      user = Emisar.Fixtures.user_fixture()
      {conn, token_id, _secret} = request_magic_link(conn, user.email)

      # `tamper` isn't 6 digits, so it can never hash-match the real secret.
      conn = get(conn, ~p"/sign_in/magic/#{token_id}/tamper")

      assert redirected_to(conn) == ~p"/sign_in/magic"
      refute get_session(conn, :user_token)
    end

    test "a soft-deleted user cannot sign in via the link", %{conn: conn} do
      user = Emisar.Fixtures.user_fixture()
      {conn, token_id, secret} = request_magic_link(conn, user.email)
      {:ok, _} = user |> Users.User.Changeset.delete() |> Repo.update()

      conn = get(conn, ~p"/sign_in/magic/#{token_id}/#{secret}")

      assert redirected_to(conn) == ~p"/sign_in/magic"
      refute get_session(conn, :user_token)
    end

    test "an unknown email still lands on the check-email page (no account-existence leak)",
         %{conn: conn} do
      conn =
        post(conn, ~p"/sign_in/magic/start", %{"user" => %{"email" => "nobody@example.test"}})

      assert redirected_to(conn) == ~p"/sign_in/magic?sent=1"
      # No email sent, no cookie planted — but the page is identical to a hit.
      refute_received {:email, _}
      refute conn.resp_cookies["emisar_magic"]
    end
  end

  describe "DELETE /sign_out" do
    test "logs the user out, clears the session, and invalidates the token", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      token = Plug.Conn.get_session(conn, :user_token)
      assert token

      conn = delete(conn, ~p"/sign_out")

      assert redirected_to(conn) == "/"
      refute Plug.Conn.get_session(conn, :user_token)
      # The token is actually killed server-side, not just dropped from the
      # session — a stolen copy can't be replayed.
      assert {:error, :not_found} = Emisar.Auth.fetch_user_and_token_by_session_token(token)
    end

    test "is a harmless redirect when no one is signed in", %{conn: conn} do
      conn = delete(conn, ~p"/sign_out")
      assert redirected_to(conn) == "/"
    end

    test "audits user.signed_out attributed to the signed-out user", %{conn: conn} do
      # the sign-out event must be attributable, which is why
      # `log_out_user` resolves the actor from `conn.assigns.current_user` and audits
      # BEFORE dropping the token (dropping it first would lose the only id). The
      # observable proof: after sign-out a `user.signed_out` row exists on the user's
      # account naming them as the subject — even though their token is now gone.
      {conn, user, account} = register_and_log_in(conn)

      conn = delete(conn, ~p"/sign_out")
      assert redirected_to(conn) == "/"

      events =
        Event.Query.all()
        |> Event.Query.by_account_id(account.id)
        |> Event.Query.by_event_type("user.signed_out")
        |> Event.Query.by_subject_id(user.id)
        |> Repo.all()

      assert length(events) == 1
    end

    test "is CSRF-protected — a sign-out without a token is rejected by the browser pipeline",
         %{conn: conn} do
      # /sign_out runs the :browser pipeline (`protect_from_forgery`),
      # so a cross-site forced logout (a DELETE with no CSRF token) is blocked. The
      # test conn defaults to `plug_skip_csrf_protection: true`; clearing it exercises
      # the real protection, which raises InvalidCSRFTokenError → a 403.
      {conn, _user, _account} = register_and_log_in(conn)

      conn = Plug.Conn.put_private(conn, :plug_skip_csrf_protection, false)

      assert_error_sent(403, fn -> delete(conn, ~p"/sign_out") end)
    end
  end

  describe "POST /sign_in?_action=registered (sign-up auto-login)" do
    test "flashes the confirmation-email notice so it isn't silent", %{conn: conn} do
      # register_and_log_in builds a real user+account; reuse the credentials in
      # a fresh, signed-out conn to drive the registration auto-login POST.
      {_logged_in, user, _account} = register_and_log_in(conn)

      conn =
        build_conn()
        |> post(~p"/sign_in?_action=registered", %{
          "user" => %{"email" => user.email, "password" => "very-long-password-here"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "confirmation link to #{user.email}"
    end
  end
end
