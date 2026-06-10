defmodule EmisarWeb.AuthFlowTest do
  use EmisarWeb.ConnCase, async: true

  describe "GET /sign_in" do
    test "renders the sign-in form", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/sign_in")
      assert html =~ "Welcome back"
      assert html =~ "Work email"
      assert html =~ "Password"
    end

    test "redirects authenticated users to /app", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      assert {:error, {:redirect, %{to: "/app"}}} = live(conn, ~p"/sign_in")
    end
  end

  describe "GET /sign_up" do
    test "renders the registration form", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/sign_up")
      assert html =~ "Start your free workspace"
      assert html =~ "Work email"
      assert html =~ "Password"
    end
  end

  describe "POST /sign_in" do
    setup do
      {:ok, user} =
        Emisar.Accounts.register_user(%{
          email: "test@example.com",
          full_name: "Test User",
          password: "very-long-password-1234"
        })

      Emisar.Fixtures.confirm_user(user)
      :ok
    end

    test "logs in with correct credentials", %{conn: conn} do
      conn =
        post(conn, ~p"/sign_in", %{
          "user" => %{
            "email" => "test@example.com",
            "password" => "very-long-password-1234"
          }
        })

      assert redirected_to(conn) == ~p"/app"
      assert get_session(conn, :user_token)
    end

    test "rejects wrong password and preserves email in flash", %{conn: conn} do
      conn =
        post(conn, ~p"/sign_in", %{
          "user" => %{
            "email" => "test@example.com",
            "password" => "not-the-real-one-1234"
          }
        })

      assert redirected_to(conn) == ~p"/sign_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "don't match"
      assert Phoenix.Flash.get(conn.assigns.flash, :email) == "test@example.com"
    end
  end

  describe "MFA step-up flow" do
    setup do
      {:ok, user} =
        Emisar.Accounts.register_user(%{
          email: "mfa@example.com",
          full_name: "MFA User",
          password: "long-mfa-password-123"
        })

      user = Emisar.Fixtures.confirm_user(user)

      # The user needs a membership for the `user.signed_in` audit
      # broadcast (and the post-sign-in redirect) to find an account.
      # owner_subject_fixture creates an account + binds it to a NEW
      # user; here we want the membership tied to OUR user, so build
      # it inline.
      {:ok, account} =
        Emisar.Accounts.create_account_with_owner(
          %{
            name: "MFA Test",
            slug: "mfa-test-#{System.unique_integer([:positive])}",
            plan: "free"
          },
          user
        )

      # Enable MFA so the user has a TOTP secret on the row.
      secret = Emisar.Auth.generate_mfa_secret()

      {:ok, user, _codes} =
        Emisar.Auth.enable_mfa(user, secret, NimbleTOTP.verification_code(secret))

      %{user: user, secret: secret, account: account}
    end

    test "correct password sets a pending-MFA session marker and redirects to /sign_in/mfa", %{
      conn: conn
    } do
      conn =
        post(conn, ~p"/sign_in", %{
          "user" => %{"email" => "mfa@example.com", "password" => "long-mfa-password-123"}
        })

      assert redirected_to(conn) == ~p"/sign_in/mfa"
      # No user_token yet — sign-in isn't finished.
      refute get_session(conn, :user_token)
      # Pending marker stashes the user_id with a TTL.
      assert is_binary(get_session(conn, :pending_mfa_user_id))
      assert is_integer(get_session(conn, :pending_mfa_expires_at))
    end

    test "OTP submitted against a valid pending marker finishes sign-in WITHOUT asking for the password again",
         %{conn: conn, secret: secret, account: account} do
      # Step 1: password verifies, pending marker set.
      conn =
        post(conn, ~p"/sign_in", %{
          "user" => %{"email" => "mfa@example.com", "password" => "long-mfa-password-123"}
        })

      assert redirected_to(conn) == ~p"/sign_in/mfa"

      # Step 2: submit OTP only — no email, no password in the form.
      otp = NimbleTOTP.verification_code(secret)

      conn = post(conn, ~p"/sign_in", %{"user" => %{"otp" => otp}})

      assert redirected_to(conn) == ~p"/app"
      assert get_session(conn, :user_token)
      # Pending marker is cleared once the sign-in succeeds.
      refute get_session(conn, :pending_mfa_user_id)
      refute get_session(conn, :pending_mfa_expires_at)

      # And user.signed_in is audit-logged with the MFA method.
      {:ok, events, _} =
        Emisar.Audit.list_events(
          Emisar.Auth.Subject.system(account),
          filter: [event_type: ["user.signed_in"]]
        )

      assert Enum.any?(events, fn ev -> ev.payload["method"] == "password+mfa" end)
    end

    test "wrong OTP under a valid pending marker stays on /sign_in/mfa with a flash", %{
      conn: conn
    } do
      conn =
        post(conn, ~p"/sign_in", %{
          "user" => %{"email" => "mfa@example.com", "password" => "long-mfa-password-123"}
        })

      assert redirected_to(conn) == ~p"/sign_in/mfa"

      # Wrong code — should land back on /sign_in/mfa, NOT /sign_in.
      conn = post(conn, ~p"/sign_in", %{"user" => %{"otp" => "000000"}})

      assert redirected_to(conn) == ~p"/sign_in/mfa"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "didn't match"
      # Pending marker stays so the user can try again.
      assert get_session(conn, :pending_mfa_user_id)
    end

    test "an OTP submission without a pending marker bounces back to /sign_in (instead of crashing)",
         %{conn: conn} do
      # The visitor never ran the password step — just hit /sign_in
      # with an OTP. Without a pending marker, that's not a valid
      # second-step submission; we send them to the password page.
      conn = post(conn, ~p"/sign_in", %{"user" => %{"otp" => "123456"}})

      assert redirected_to(conn) == ~p"/sign_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "expired"
    end

    test "the MFA challenge LV bounces visitors with no pending state back to /sign_in", %{
      conn: conn
    } do
      assert {:error, {:live_redirect, %{to: "/sign_in"}}} = live(conn, ~p"/sign_in/mfa")
    end
  end

  describe "GET /reset_password" do
    test "renders the request form", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/reset_password")
      assert html =~ "Reset your password"
    end
  end

  describe "GET /sign_in/magic" do
    test "renders the magic-link form", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/sign_in/magic")
      assert html =~ "Sign in via email"
    end
  end
end
