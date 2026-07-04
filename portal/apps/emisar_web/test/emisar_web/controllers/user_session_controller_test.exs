defmodule EmisarWeb.UserSessionControllerTest do
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Audit.Event
  alias Emisar.{Auth, Repo, Users}
  alias EmisarWeb.{MagicLinkHandoff, MfaChallengeHandoff}

  describe "split-code magic link" do
    # Drive the real request, then pull token_id + the 6-char secret out of the
    # email. The returned conn carries the signed nonce cookie (via recycle), so a
    # follow-up confirm/code request is "the same browser" that requested.
    defp request_magic_link(conn, email) do
      conn = post(conn, ~p"/sign_in/magic/start", %{"user" => %{"email" => email}})
      assert_received {:email, sent}
      [_, token_id, secret] = Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", sent.text_body)
      {recycle(conn), token_id, secret}
    end

    setup do
      %{user: Fixtures.Users.create_user()}
    end

    test "POST /start sets the nonce cookie and lands on the check-email page", %{
      conn: conn,
      user: user
    } do
      conn = post(conn, ~p"/sign_in/magic/start", %{"user" => %{"email" => user.email}})

      assert redirected_to(conn) == ~p"/sign_in/magic?sent=1"
      assert conn.resp_cookies["emisar_magic"]
    end

    # The sign-up form posts `registration=1` to /start; the flag rides the magic
    # cookie through the round-trip so the FIRST sign-in fires sign_up_completed.
    # The welcome flash is the observable proxy (same `registered?` signal drives
    # both it and the analytics event), since the analytics seam is off in test.
    test "a registration round-trip welcomes the new operator", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/sign_in/magic/start", %{
          "user" => %{"email" => user.email},
          "registration" => "1"
        })

      assert_received {:email, sent}
      [_, token_id, secret] = Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", sent.text_body)

      conn = get(recycle(conn), ~p"/sign_in/magic/#{token_id}/#{secret}")

      assert get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome to emisar"
    end

    test "a normal sign-in (no registration) shows no welcome", %{conn: conn, user: user} do
      conn = post(conn, ~p"/sign_in/magic/start", %{"user" => %{"email" => user.email}})

      assert_received {:email, sent}
      [_, token_id, secret] = Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", sent.text_body)

      conn = get(recycle(conn), ~p"/sign_in/magic/#{token_id}/#{secret}")

      assert get_session(conn, :user_token)
      refute (Phoenix.Flash.get(conn.assigns.flash, :info) || "") =~ "Welcome to emisar"
    end

    test "the email link signs in from the originating browser", %{conn: conn, user: user} do
      {conn, token_id, secret} = request_magic_link(conn, user.email)

      conn = get(conn, ~p"/sign_in/magic/#{token_id}/#{secret}")

      assert token = get_session(conn, :user_token)
      assert {:ok, signed_in, _} = Auth.fetch_user_and_token_by_session_token(token)
      assert signed_in.id == user.id
    end

    # The typed code is verified in MagicLinkLive (tested there); it then redirects
    # here with a handoff to establish the session. These cover the completion +
    # its browser-binding — the handoff alone is never enough.
    test "a valid handoff from the requesting browser completes sign-in", %{
      conn: conn,
      user: user
    } do
      {conn, token_id, _secret} = request_magic_link(conn, user.email)
      handoff = MagicLinkHandoff.sign(user.id, false, token_id)

      conn = get(conn, ~p"/sign_in/magic/complete?#{[handoff: handoff]}")

      assert token = get_session(conn, :user_token)
      assert {:ok, signed_in, _} = Auth.fetch_user_and_token_by_session_token(token)
      assert signed_in.id == user.id
    end

    test "a handoff WITHOUT the requesting browser's cookie can't sign in (anti-hijack)", %{
      conn: conn,
      user: user
    } do
      {_conn, token_id, _secret} = request_magic_link(conn, user.email)
      handoff = MagicLinkHandoff.sign(user.id, false, token_id)

      # A leaked handoff URL opened in a DIFFERENT browser (fresh conn, no magic
      # cookie) → no sign-in. The binding that makes the URL credential safe.
      conn = get(build_conn(), ~p"/sign_in/magic/complete?#{[handoff: handoff]}")

      assert redirected_to(conn) == ~p"/sign_in/magic?sent=1"
      refute get_session(conn, :user_token)
    end

    test "a handoff bound to a different token than the cookie's flow is refused", %{
      conn: conn,
      user: user
    } do
      {conn, _token_id, _secret} = request_magic_link(conn, user.email)
      handoff = MagicLinkHandoff.sign(user.id, false, "not-the-cookie-token-id")

      conn = get(conn, ~p"/sign_in/magic/complete?#{[handoff: handoff]}")

      assert redirected_to(conn) == ~p"/sign_in/magic?sent=1"
      refute get_session(conn, :user_token)
    end

    test "a forged/garbage handoff is refused", %{conn: conn, user: user} do
      {conn, _token_id, _secret} = request_magic_link(conn, user.email)

      conn = get(conn, ~p"/sign_in/magic/complete?#{[handoff: "not-a-real-token"]}")

      assert redirected_to(conn) == ~p"/sign_in/magic?sent=1"
      refute get_session(conn, :user_token)
    end

    test "the link WITHOUT the requesting browser's cookie can't sign in (anti-hijack)",
         %{conn: conn, user: user} do
      {_conn, token_id, secret} = request_magic_link(conn, user.email)

      # A DIFFERENT browser (fresh conn, no nonce cookie) clicking the intercepted
      # link → no sign-in. The core web-level hijack guarantee.
      conn = get(build_conn(), ~p"/sign_in/magic/#{token_id}/#{secret}")

      assert redirected_to(conn) == ~p"/sign_in/magic?sent=1"
      refute get_session(conn, :user_token)
    end

    test "a wrong secret is uniformly invalid (no oracle)", %{conn: conn, user: user} do
      {conn, token_id, _secret} = request_magic_link(conn, user.email)

      # `tamper` can never hash-match the real secret, so it's uniformly invalid.
      conn = get(conn, ~p"/sign_in/magic/#{token_id}/tamper")

      assert redirected_to(conn) == ~p"/sign_in/magic?sent=1"
      refute get_session(conn, :user_token)
    end

    test "a soft-deleted user cannot sign in via the link", %{conn: conn, user: user} do
      {conn, token_id, secret} = request_magic_link(conn, user.email)
      {:ok, _} = user |> Users.User.Changeset.delete() |> Repo.update()

      conn = get(conn, ~p"/sign_in/magic/#{token_id}/#{secret}")

      assert redirected_to(conn) == ~p"/sign_in/magic?sent=1"
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

    test "the typed address + the code's expiry are stashed for the sent page", %{
      conn: conn,
      user: user
    } do
      conn = post(conn, ~p"/sign_in/magic/start", %{"user" => %{"email" => user.email}})
      assert get_session(conn, :magic_link_email) == user.email

      assert {:ok, %DateTime{}, _} =
               DateTime.from_iso8601(get_session(conn, :magic_link_expires_at))
    end

    test "a send under the throttle shows no error flash", %{conn: conn, user: user} do
      conn = post(conn, ~p"/sign_in/magic/start", %{"user" => %{"email" => user.email}})
      conn = get(recycle(conn), ~p"/sign_in/magic?sent=1")
      assert (Phoenix.Flash.get(conn.assigns.flash, :error) || "") == ""
    end

    test "a rate-limited send surfaces the same throttle error for an UNKNOWN address (no account leak)",
         %{conn: conn} do
      previous = Application.get_env(:emisar_web, :rate_limit_enabled, true)
      Application.put_env(:emisar_web, :rate_limit_enabled, true)
      on_exit(fn -> Application.put_env(:emisar_web, :rate_limit_enabled, previous) end)

      # The throttle is checked BEFORE the user lookup, so the 6th request for an
      # address that ISN'T an account is throttled and surfaces the SAME message a
      # real account would — the error can never reveal whether the address exists.
      params = %{"user" => %{"email" => "ghost@example.test"}}
      for _ <- 1..5, do: post(conn, ~p"/sign_in/magic/start", params)
      conn = post(conn, ~p"/sign_in/magic/start", params)

      assert redirected_to(conn) == ~p"/sign_in/magic?sent=1"
      conn = get(recycle(conn), ~p"/sign_in/magic?sent=1")
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Wait a few minutes"
    end
  end

  describe "MFA sign-in challenge" do
    defp enrolled_mfa_user do
      user = Fixtures.Users.create_user() |> Fixtures.Users.confirm_user()
      account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

      secret = Auth.generate_mfa_secret()
      {user, _codes} = Fixtures.Users.enable_mfa!(secret, owner_subject(user, account))
      %{user: user, account: account}
    end

    test "an mfa-enrolled user lands on the challenge, not a full session (email link)", %{
      conn: conn
    } do
      %{user: user} = enrolled_mfa_user()
      {conn, token_id, secret} = request_magic_link(conn, user.email)

      conn = get(conn, ~p"/sign_in/magic/#{token_id}/#{secret}")

      # No session token minted → not authenticated → no /app access. Only the
      # non-granting pending marker is set.
      refute get_session(conn, :user_token)
      assert get_session(conn, :mfa_pending_user_id) == user.id
      assert redirected_to(conn) == ~p"/sign_in/mfa"
    end

    test "the typed-code completion also diverts an mfa user to the challenge", %{conn: conn} do
      %{user: user} = enrolled_mfa_user()
      {conn, token_id, _secret} = request_magic_link(conn, user.email)
      handoff = MagicLinkHandoff.sign(user.id, false, token_id)

      conn = get(conn, ~p"/sign_in/magic/complete?#{[handoff: handoff]}")

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/sign_in/mfa"
    end

    test "a user without mfa still signs straight in (the branch doesn't over-fire)", %{
      conn: conn
    } do
      user = Fixtures.Users.create_user()
      {conn, token_id, secret} = request_magic_link(conn, user.email)

      conn = get(conn, ~p"/sign_in/magic/#{token_id}/#{secret}")

      assert get_session(conn, :user_token)
      refute get_session(conn, :mfa_pending_user_id)
    end

    test "mfa_complete with a valid handoff + matching pending session signs in with mfa:true", %{
      conn: conn
    } do
      %{user: user} = enrolled_mfa_user()
      handoff = MfaChallengeHandoff.sign(user.id)

      conn =
        conn
        |> init_test_session(%{mfa_pending_user_id: user.id, mfa_pending_registered?: false})
        |> get(~p"/sign_in/mfa/complete?#{[handoff: handoff]}")

      assert token = get_session(conn, :user_token)
      assert {:ok, signed_in, session_token} = Auth.fetch_user_and_token_by_session_token(token)
      assert signed_in.id == user.id
      # The second factor is stamped onto the token so it reaches every audit row.
      assert session_token.mfa == true
      refute get_session(conn, :mfa_pending_user_id)
    end

    test "mfa_complete with a handoff but NO pending session is refused (the bypass)", %{
      conn: conn
    } do
      %{user: user} = enrolled_mfa_user()
      handoff = MfaChallengeHandoff.sign(user.id)

      conn = get(init_test_session(conn, %{}), ~p"/sign_in/mfa/complete?#{[handoff: handoff]}")

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/sign_in/magic"
    end

    test "mfa_complete refuses a handoff that doesn't match the pending user", %{conn: conn} do
      %{user: user} = enrolled_mfa_user()
      other_handoff = MfaChallengeHandoff.sign(Ecto.UUID.generate())

      conn =
        conn
        |> init_test_session(%{mfa_pending_user_id: user.id})
        |> get(~p"/sign_in/mfa/complete?#{[handoff: other_handoff]}")

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/sign_in/magic"
    end

    test "mfa_complete refuses a forged/garbage handoff", %{conn: conn} do
      %{user: user} = enrolled_mfa_user()

      conn =
        conn
        |> init_test_session(%{mfa_pending_user_id: user.id})
        |> get(~p"/sign_in/mfa/complete?#{[handoff: "not-a-real-token"]}")

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/sign_in/magic"
    end

    test "a partial (mfa-pending) session cannot reach an app route", %{conn: conn} do
      %{user: user, account: account} = enrolled_mfa_user()

      conn =
        conn
        |> init_test_session(%{mfa_pending_user_id: user.id})
        |> get(~p"/app/#{account}")

      assert redirected_to(conn) =~ "/sign_in"
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
        |> Event.Query.by_target_id(user.id)
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
end
