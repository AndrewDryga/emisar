defmodule EmisarWeb.UserSessionControllerTest do
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Accounts, Auth, Repo, Users}
  alias Emisar.Audit.Event
  alias EmisarWeb.{MagicLinkHandoff, MfaChallengeHandoff, RegistrationHandoff}

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

    defp verify_magic_factor(conn, user) do
      conn = post(conn, ~p"/sign_in/magic/start", %{"user" => %{"email" => user.email}})
      assert_received {:email, sent}
      [_, token_id, secret] = Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", sent.text_body)
      nonce = get_session(conn, :magic_link_nonce)
      assert {:ok, %Users.User{id: user_id}} = Auth.verify_magic_link(token_id, secret, nonce)
      assert user_id == user.id
      {recycle(conn), token_id}
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

    test "the split-factor cookie follows the runtime secure-cookie setting", %{
      conn: conn,
      user: user
    } do
      Emisar.Config.put_override(:emisar_web, :force_secure_cookies, true)

      secure = post(conn, ~p"/sign_in/magic/start", %{"user" => %{"email" => user.email}})
      assert secure.resp_cookies["emisar_magic"].secure
      assert_received {:email, _}

      Emisar.Config.put_override(:emisar_web, :force_secure_cookies, false)

      local =
        post(build_conn(), ~p"/sign_in/magic/start", %{"user" => %{"email" => user.email}})

      refute local.resp_cookies["emisar_magic"].secure
      assert_received {:email, _}
    end

    # A request branded to a team that isn't available mints and sends nothing —
    # but the response is the same neutral sent page an unknown address gets, so
    # /start never becomes an account- or tenant-existence oracle.
    test "a disabled branded account issues nothing and still looks like a send", %{
      conn: conn,
      user: user
    } do
      account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

      Fixtures.Accounts.disable_account(account)

      conn =
        post(conn, ~p"/sign_in/magic/start", %{
          "user" => %{"email" => user.email},
          "return_to" => "/app/#{account.slug}"
        })

      assert redirected_to(conn) == ~p"/sign_in/magic?sent=1"
      assert conn.resp_cookies["emisar_magic"].max_age == 900
      assert is_binary(get_session(conn, :magic_link_token_id))
      assert is_binary(get_session(conn, :magic_link_nonce))
      refute_received {:email, _}
    end

    # The sign-up form posts a signed registration handoff to /start; the
    # verified user id rides the magic cookie through the round-trip so the FIRST
    # sign-in fires sign_up_completed. The welcome flash is the observable proxy
    # (same `registered?` signal drives both it and the analytics event), since
    # the analytics seam is off in test.
    test "a registration round-trip welcomes the new operator", %{conn: conn} do
      user = Fixtures.Users.create_user(confirmed?: false)

      conn =
        post(conn, ~p"/sign_in/magic/start", %{
          "user" => %{"email" => user.email},
          "registration_handoff" =>
            RegistrationHandoff.sign(user.id, "Welcome Co", "Welcome Owner")
        })

      assert_received {:email, sent}
      [_, token_id, secret] = Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", sent.text_body)

      conn = get(recycle(conn), ~p"/sign_in/magic/#{token_id}/#{secret}")

      assert get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome to emisar"
    end

    test "a resend with no posted handoff retains the server-side registration intent", %{
      conn: conn
    } do
      user = Fixtures.Users.create_user(confirmed?: false, full_name: "Unproved Name")
      handoff = RegistrationHandoff.sign(user.id, "Resend Co", "Inbox Owner")

      started =
        post(conn, ~p"/sign_in/magic/start", %{
          "user" => %{"email" => user.email},
          "registration_handoff" => handoff
        })

      assert_received {:email, _first_sent}

      resent =
        post(recycle(started), ~p"/sign_in/magic/start", %{
          "user" => %{"email" => user.email}
        })

      assert_received {:email, second_sent}

      [_, token_id, secret] =
        Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", second_sent.text_body)

      completed = get(recycle(resent), ~p"/sign_in/magic/#{token_id}/#{secret}")

      assert get_session(completed, :user_token)
      assert Phoenix.Flash.get(completed.assigns.flash, :info) =~ "Welcome to emisar"
      assert Repo.reload!(user).full_name == "Inbox Owner"
      assert %Emisar.Accounts.Account{name: "Resend Co"} = Repo.one(Emisar.Accounts.Account)
    end

    test "a throttled resend preserves the exact registration factor and intent", %{conn: conn} do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      user = Fixtures.Users.create_user(confirmed?: false)
      handoff = RegistrationHandoff.sign(user.id, "Throttled Co", "Inbox Owner")

      started =
        post(conn, ~p"/sign_in/magic/start", %{
          "user" => %{"email" => user.email},
          "registration_handoff" => handoff
        })

      assert_received {:email, _first}

      {current, latest_email} =
        Enum.reduce(1..4, {started, nil}, fn _, {prior, _email} ->
          resent =
            post(recycle(prior), ~p"/sign_in/magic/start", %{
              "user" => %{"email" => user.email}
            })

          assert_received {:email, sent}
          {resent, sent}
        end)

      preserved_id = get_session(current, :magic_link_token_id)
      preserved_nonce = get_session(current, :magic_link_nonce)

      throttled =
        post(recycle(current), ~p"/sign_in/magic/start", %{
          "user" => %{"email" => user.email}
        })

      refute_received {:email, _}
      assert redirected_to(throttled) == ~p"/sign_in/magic?sent=1"
      assert get_session(throttled, :magic_link_token_id) == preserved_id
      assert get_session(throttled, :magic_link_nonce) == preserved_nonce

      [_, ^preserved_id, secret] =
        Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", latest_email.text_body)

      completed = get(recycle(throttled), ~p"/sign_in/magic/#{preserved_id}/#{secret}")

      assert get_session(completed, :user_token)
      assert %Emisar.Accounts.Account{name: "Throttled Co"} = Repo.one(Emisar.Accounts.Account)
      assert Repo.reload!(user).full_name == "Inbox Owner"
    end

    test "a throttled signup submission clears stale browser state and returns to signup", %{
      conn: conn
    } do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      user = Fixtures.Users.create_user(confirmed?: false)
      handoff = RegistrationHandoff.sign(user.id, "Retry Signup Co", "Inbox Owner")

      started =
        post(conn, ~p"/sign_in/magic/start", %{
          "user" => %{"email" => user.email},
          "registration_handoff" => handoff
        })

      assert_received {:email, _first}

      current =
        Enum.reduce(1..4, started, fn _, prior ->
          resent =
            post(recycle(prior), ~p"/sign_in/magic/start", %{
              "user" => %{"email" => user.email}
            })

          assert_received {:email, _sent}
          resent
        end)

      throttled =
        post(recycle(current), ~p"/sign_in/magic/start", %{
          "user" => %{"email" => user.email},
          "registration_handoff" => handoff
        })

      refute_received {:email, _}
      assert redirected_to(throttled) == ~p"/sign_up"
      assert get_session(throttled, :magic_link_token_id) == nil
      assert get_session(throttled, :magic_link_nonce) == nil
      assert throttled.resp_cookies["emisar_magic"].max_age == 0
      assert Phoenix.Flash.get(throttled.assigns.flash, :error) =~ "try signup again"
    end

    test "a decoy signup handoff gives an existing operator the same neutral magic path", %{
      conn: conn,
      user: user
    } do
      handoff = RegistrationHandoff.decoy("Existing Co", "Existing Owner")

      conn =
        post(conn, ~p"/sign_in/magic/start", %{
          "user" => %{"email" => user.email},
          "registration_handoff" => handoff
        })

      assert redirected_to(conn) == ~p"/sign_in/magic?sent=1"
      assert conn.resp_cookies["emisar_magic"]
      refute get_session(conn, :magic_link_signup_handoff)

      assert_received {:email, sent}
      [_, token_id, secret] = Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", sent.text_body)

      conn = get(recycle(conn), ~p"/sign_in/magic/#{token_id}/#{secret}")

      assert get_session(conn, :user_token)
      refute (Phoenix.Flash.get(conn.assigns.flash, :info) || "") =~ "Welcome to emisar"
    end

    test "new and existing signup starts expose the same cookie and LiveView session shape", %{
      conn: conn
    } do
      suffix = Ecto.UUID.generate()

      new_user =
        Fixtures.Users.create_user(%{
          email: "new-#{suffix}@example.test",
          full_name: "Neutral Owner",
          confirmed?: false
        })

      existing = Fixtures.Users.create_user(%{email: "old-#{suffix}@example.test"})

      new_handoff = RegistrationHandoff.sign(new_user.id, "Neutral Co", "Neutral Owner")
      decoy_handoff = RegistrationHandoff.decoy("Neutral Co", "Neutral Owner")
      assert byte_size(new_handoff) == byte_size(decoy_handoff)

      new_conn =
        post(conn, ~p"/sign_in/magic/start", %{
          "user" => %{"email" => new_user.email},
          "registration_handoff" => new_handoff
        })

      assert_received {:email, _}

      existing_conn =
        post(build_conn(), ~p"/sign_in/magic/start", %{
          "user" => %{"email" => existing.email},
          "registration_handoff" => decoy_handoff
        })

      assert_received {:email, _}

      assert response_cookie_lengths(new_conn) == response_cookie_lengths(existing_conn)

      new_live_session = EmisarWeb.Router.auth_live_session(new_conn)
      existing_live_session = EmisarWeb.Router.auth_live_session(existing_conn)

      assert session_value_lengths(new_live_session) ==
               session_value_lengths(existing_live_session)

      refute Map.has_key?(new_live_session, "magic_link_signup_handoff")
      refute Map.has_key?(existing_live_session, "magic_link_signup_handoff")

      new_html = new_conn |> recycle() |> get(~p"/sign_in/magic?sent=1") |> html_response(200)

      existing_html =
        existing_conn |> recycle() |> get(~p"/sign_in/magic?sent=1") |> html_response(200)

      refute new_html =~ new_handoff
      refute existing_html =~ decoy_handoff
    end

    test "maximum attribution fits the cookie while signup values remain POST-only", %{
      conn: conn
    } do
      email = String.duplicate("a", 241) <> "@example.test"
      user = Fixtures.Users.create_user(%{email: email, confirmed?: false})
      account_name = String.duplicate("🧭", 80)
      full_name = String.duplicate("🧭", 255)
      handoff = RegistrationHandoff.sign(user.id, account_name, full_name)

      attribution =
        ~w(utm_source utm_medium utm_campaign utm_term utm_content twclid)
        |> Map.new(&{&1, String.duplicate("x", 255)})

      conn =
        conn
        |> Plug.Test.init_test_session(%{analytics_campaign_attribution: attribution})
        |> post(~p"/sign_in/magic/start", %{
          "user" => %{"email" => user.email},
          "registration_handoff" => handoff
        })

      assert redirected_to(conn) == ~p"/sign_in/magic?sent=1"
      assert_received {:email, _}
      assert Enum.all?(get_resp_header(conn, "set-cookie"), &(byte_size(&1) < 4_096))
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

    test "a branded account disabled after the link was issued mints nothing", %{
      conn: conn,
      user: user
    } do
      account = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

      {conn, token_id, secret} = request_magic_link(conn, user.email)
      Fixtures.Accounts.disable_account(account)

      conn =
        get(
          conn,
          ~p"/sign_in/magic/#{token_id}/#{secret}?#{[return_to: "/app/#{account.slug}"]}"
        )

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/app/#{account}/sign_in"
    end

    test "one login audits user.signed_in exactly once per account", %{conn: conn, user: user} do
      # Audit rows are membership-scoped, so create a membership.
      account = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: account.id, user_id: user.id)

      {conn, token_id, secret} = request_magic_link(conn, user.email)
      conn = get(conn, ~p"/sign_in/magic/#{token_id}/#{secret}")
      assert get_session(conn, :user_token)

      signed_in_events =
        Event.Query.all()
        |> Event.Query.by_event_type("user.signed_in")
        |> Repo.all()

      assert length(signed_in_events) == 1
    end

    # The typed code is verified in MagicLinkLive (tested there); it then redirects
    # here with a handoff to establish the session. These cover the completion +
    # its browser-binding — the handoff alone is never enough.
    test "a valid handoff from the requesting browser completes sign-in", %{
      conn: conn,
      user: user
    } do
      {conn, token_id} = verify_magic_factor(conn, user)
      handoff = MagicLinkHandoff.sign(user.id, token_id)

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
      handoff = MagicLinkHandoff.sign(user.id, token_id)

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
      handoff = MagicLinkHandoff.sign(user.id, "not-the-cookie-token-id")

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

    test "known and unknown addresses expose the same browser state, while a decoy grants nothing",
         %{conn: conn} do
      suffix = Ecto.UUID.generate()
      known_email = "known-#{suffix}@example.test"
      unknown_email = "ghost-#{suffix}@example.test"
      _user = Fixtures.Users.create_user(%{email: known_email})

      known_conn =
        post(conn, ~p"/sign_in/magic/start", %{"user" => %{"email" => known_email}})

      assert_received {:email, _}

      unknown_conn =
        post(build_conn(), ~p"/sign_in/magic/start", %{
          "user" => %{"email" => unknown_email}
        })

      refute_received {:email, _}
      assert redirected_to(unknown_conn) == ~p"/sign_in/magic?sent=1"
      assert unknown_conn.resp_cookies["emisar_magic"].max_age == 900
      assert response_cookie_lengths(known_conn) == response_cookie_lengths(unknown_conn)

      known_session = EmisarWeb.Router.auth_live_session(known_conn)
      unknown_session = EmisarWeb.Router.auth_live_session(unknown_conn)
      assert session_value_lengths(known_session) == session_value_lengths(unknown_session)
      refute Map.has_key?(known_session, "magic_link_token_id")
      refute Map.has_key?(known_session, "magic_link_nonce")
      refute Map.has_key?(unknown_session, "magic_link_token_id")
      refute Map.has_key?(unknown_session, "magic_link_nonce")

      known_id = get_session(known_conn, :magic_link_token_id)
      decoy_id = get_session(unknown_conn, :magic_link_token_id)
      assert String.at(known_id, 14) == "7"
      assert String.at(decoy_id, 14) == "7"

      {:ok, live, _html} = live(recycle(unknown_conn), ~p"/sign_in/magic?sent=1")
      assert render_hook(live, "verify_code", %{"code" => "ABC123"}) =~ "match or has expired"

      completed = get(recycle(unknown_conn), ~p"/sign_in/magic/#{decoy_id}/ABC123")
      refute get_session(completed, :user_token)
    end

    test "malformed magic-link email fields get the same neutral sent response", %{conn: conn} do
      for params <- [
            %{"user" => %{"email" => %{"nested" => "value"}}},
            %{"user" => "not-a-map"},
            %{}
          ] do
        response = post(conn, ~p"/sign_in/magic/start", params)

        assert redirected_to(response) == ~p"/sign_in/magic?sent=1"
      end

      refute_received {:email, _email}
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
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)

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
      {user, codes} = Fixtures.Users.enable_mfa!(secret, owner_subject(user, account))
      %{user: user, account: account, secret: secret, codes: codes}
    end

    defp verified_handoff(user, secret) do
      {:ok, proof} =
        Auth.verify_mfa_challenge(user, {:totp, NimbleTOTP.verification_code(secret)})

      MfaChallengeHandoff.sign(proof)
    end

    defp pending_mfa_sign_in(conn, user, secret) do
      {conn, token_id} = verify_magic_factor(conn, user)
      {conn, token_id, verified_handoff(user, secret)}
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
      {conn, token_id} = verify_magic_factor(conn, user)
      handoff = MagicLinkHandoff.sign(user.id, token_id)

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
      %{user: user, secret: secret} = enrolled_mfa_user()
      {conn, token_id, handoff} = pending_mfa_sign_in(conn, user, secret)

      conn =
        conn
        |> init_test_session(%{
          mfa_pending_user_id: user.id,
          mfa_pending_magic_link_token_id: token_id,
          mfa_pending_registered?: false,
          mfa_pending_at: System.system_time(:second)
        })
        |> get(~p"/sign_in/mfa/complete?#{[handoff: handoff]}")

      assert token = get_session(conn, :user_token)
      assert {:ok, signed_in, session_token} = Auth.fetch_user_and_token_by_session_token(token)
      assert signed_in.id == user.id
      # The proof time is stamped onto the token, so the factor claim reaches every
      # audit row bound to the enrollment it was taken against.
      assert %DateTime{} = session_token.mfa_verified_at
      refute get_session(conn, :mfa_pending_user_id)
    end

    test "a stale half-authentication cannot be completed later", %{conn: conn} do
      %{user: user, secret: secret} = enrolled_mfa_user()
      {conn, token_id, handoff} = pending_mfa_sign_in(conn, user, secret)

      # The verified inbox factor remains server-side for the final atomic mint,
      # but the browser's right to present factor two is independently bounded.
      conn =
        conn
        |> init_test_session(%{
          mfa_pending_user_id: user.id,
          mfa_pending_magic_link_token_id: token_id,
          mfa_pending_at: System.system_time(:second) - 3_600
        })
        |> get(~p"/sign_in/mfa/complete?#{[handoff: handoff]}")

      refute get_session(conn, :user_token)
      refute get_session(conn, :mfa_pending_user_id)
    end

    test "mfa completion rechecks a disabled branded account before minting a session", %{
      conn: conn
    } do
      %{user: user, account: account, secret: secret} = enrolled_mfa_user()
      {conn, token_id, handoff} = pending_mfa_sign_in(conn, user, secret)

      assert {:ok, _account} =
               Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "Temporary hold",
                 owner_subject(user, account)
               )

      conn =
        conn
        |> init_test_session(%{
          mfa_pending_user_id: user.id,
          mfa_pending_magic_link_token_id: token_id,
          mfa_pending_at: System.system_time(:second),
          user_return_to: "/app/#{account.slug}"
        })
        |> get(~p"/sign_in/mfa/complete?#{[handoff: handoff]}")

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/app/#{account}/sign_in"
    end

    test "mfa_complete with a handoff but NO pending session is refused (the bypass)", %{
      conn: conn
    } do
      %{user: user, secret: secret} = enrolled_mfa_user()
      handoff = verified_handoff(user, secret)

      conn = get(init_test_session(conn, %{}), ~p"/sign_in/mfa/complete?#{[handoff: handoff]}")

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/sign_in/magic"
    end

    test "mfa_complete refuses a handoff that doesn't match the pending user", %{conn: conn} do
      %{user: user} = enrolled_mfa_user()
      %{user: other_user, secret: other_secret} = enrolled_mfa_user()
      other_handoff = verified_handoff(other_user, other_secret)

      conn =
        conn
        |> init_test_session(%{
          mfa_pending_user_id: user.id,
          mfa_pending_at: System.system_time(:second)
        })
        |> get(~p"/sign_in/mfa/complete?#{[handoff: other_handoff]}")

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/sign_in/magic"
    end

    test "mfa_complete refuses a proof whose enrollment changed since the challenge", %{
      conn: conn
    } do
      %{user: user, account: account, secret: secret, codes: [code | _]} = enrolled_mfa_user()
      {conn, token_id, handoff} = pending_mfa_sign_in(conn, user, secret)

      assert {:ok, _user} = Auth.disable_mfa(code, owner_subject(user, account))

      conn =
        conn
        |> init_test_session(%{
          mfa_pending_user_id: user.id,
          mfa_pending_magic_link_token_id: token_id,
          mfa_pending_at: System.system_time(:second)
        })
        |> get(~p"/sign_in/mfa/complete?#{[handoff: handoff]}")

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/sign_in/magic"
    end

    test "mfa_complete refuses a forged/garbage handoff, or one naming only a user", %{
      conn: conn
    } do
      %{user: user} = enrolled_mfa_user()

      for handoff <- ["not-a-real-token", MfaChallengeHandoff.sign(user.id)] do
        conn =
          conn
          |> init_test_session(%{
            mfa_pending_user_id: user.id,
            mfa_pending_at: System.system_time(:second)
          })
          |> get(~p"/sign_in/mfa/complete?#{[handoff: handoff]}")

        refute get_session(conn, :user_token)
        assert redirected_to(conn) == ~p"/sign_in/magic"
      end
    end

    test "a partial (mfa-pending) session cannot reach an app route", %{conn: conn} do
      %{user: user, account: account} = enrolled_mfa_user()

      conn =
        conn
        |> init_test_session(%{
          mfa_pending_user_id: user.id,
          mfa_pending_at: System.system_time(:second)
        })
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
      assert Emisar.Auth.fetch_user_and_token_by_session_token(token) == {:error, :not_found}
    end

    test "is a harmless redirect when no one is signed in", %{conn: conn} do
      conn = delete(conn, ~p"/sign_out")
      assert redirected_to(conn) == "/"
    end

    test "audits user.signed_out attributed to the signed-out user", %{conn: conn} do
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

  defp response_cookie_lengths(conn) do
    conn
    |> get_resp_header("set-cookie")
    |> Enum.map(&byte_size/1)
    |> Enum.sort()
  end

  defp session_value_lengths(session) do
    Map.new(session, fn {key, value} -> {key, value |> to_string() |> byte_size()} end)
  end
end
