defmodule EmisarWeb.MfaChallengeLiveTest do
  @moduledoc """
  The second-factor challenge after a magic link verifies factor one. The
  partial `:mfa_pending_user_id` session names the user but grants nothing; only
  a correct TOTP or recovery code redirects to `:mfa_complete` with the handoff
  the controller trades for the session cookie.
  """
  use EmisarWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Emisar.{Auth, Fixtures}

  setup %{conn: conn} do
    user = Fixtures.Users.create_user() |> Fixtures.Users.confirm_user()
    account = Fixtures.Accounts.create_account()

    Fixtures.Memberships.create_membership(
      account_id: account.id,
      user_id: user.id,
      role: "owner"
    )

    secret = Auth.generate_mfa_secret()
    {user, recovery_codes} = Fixtures.Users.enable_mfa!(secret, owner_subject(user, account))

    conn = Plug.Test.init_test_session(conn, %{"mfa_pending_user_id" => user.id})
    %{conn: conn, user: user, secret: secret, recovery_codes: recovery_codes}
  end

  describe "mount" do
    test "no pending session redirects to the sign-in start", %{conn: _conn} do
      conn = Plug.Test.init_test_session(build_conn(), %{})

      assert {:error, {:redirect, %{to: "/sign_in/magic"}}} = live(conn, ~p"/sign_in/mfa")
    end

    test "a pending session renders the authenticator prompt", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/sign_in/mfa")

      assert html =~ "authenticator app"
      assert html =~ "Two-factor authentication"
    end
  end

  describe "TOTP verification" do
    test "a correct code redirects to completion with a handoff", %{conn: conn, secret: secret} do
      {:ok, lv, _html} = live(conn, ~p"/sign_in/mfa")

      assert {:error, {:redirect, %{to: to}}} =
               render_hook(lv, "verify_totp", %{"otp" => NimbleTOTP.verification_code(secret)})

      assert to =~ "/sign_in/mfa/complete?handoff="
    end

    test "a wrong code shows an inline error and stays put", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_in/mfa")

      html = render_hook(lv, "verify_totp", %{"otp" => "000000"})

      assert html =~ "didn&#39;t match"
    end
  end

  describe "recovery-code verification" do
    test "a valid recovery code redirects to completion", %{
      conn: conn,
      recovery_codes: [code | _]
    } do
      {:ok, lv, _html} = live(conn, ~p"/sign_in/mfa")
      render_click(lv, "use_recovery")

      assert {:error, {:redirect, %{to: to}}} =
               render_hook(lv, "verify_recovery", %{"code" => code})

      assert to =~ "/sign_in/mfa/complete?handoff="
    end

    test "a wrong recovery code shows an inline error", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_in/mfa")
      render_click(lv, "use_recovery")

      html = render_hook(lv, "verify_recovery", %{"code" => "not-a-real-code"})

      assert html =~ "didn&#39;t match or has already been used"
    end
  end

  describe "brute-force cap" do
    test "repeated wrong codes are throttled — not an endless guessing oracle", %{conn: conn} do
      Emisar.Config.put_override(:emisar_web, :rate_limit_enabled, true)

      {:ok, lv, _html} = live(conn, ~p"/sign_in/mfa")

      # Exhaust the 5-attempt window (keyed by user, so a page reload couldn't
      # reset it), then the next attempt is capped rather than probed again.
      for _ <- 1..5, do: render_hook(lv, "verify_totp", %{"otp" => "000000"})
      html = render_hook(lv, "verify_totp", %{"otp" => "000000"})

      assert html =~ "Too many attempts"
    end
  end

  describe "factor toggle" do
    test "switches between the authenticator and recovery-code entry", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/sign_in/mfa")
      assert html =~ "authenticator app"

      html = render_click(lv, "use_recovery")
      assert html =~ "recovery codes"

      html = render_click(lv, "use_totp")
      assert html =~ "authenticator app"
    end
  end
end
