defmodule EmisarWeb.MfaChallengeLiveTest do
  @moduledoc """
  The second-factor page between password and session: it must refuse
  to render without a live pending-MFA marker (no skipping the first
  factor by URL), and offer the lost-device recovery-code path.
  """
  use EmisarWeb.ConnCase, async: true

  alias Emisar.Auth

  @password "long-mfa-password-123"

  defp mfa_user! do
    {:ok, user} =
      Emisar.Users.register_user(%{
        email: "mfa-#{System.unique_integer([:positive])}@example.com",
        full_name: "MFA User",
        password: @password
      })

    user = Emisar.Fixtures.confirm_user(user)

    {:ok, account} =
      Emisar.Accounts.create_account_with_owner(
        %{name: "MFA Co", slug: "mfa-co-#{System.unique_integer([:positive])}"},
        user
      )

    secret = Auth.generate_mfa_secret()

    {user, _codes} =
      Emisar.Fixtures.enable_mfa!(secret, Emisar.Fixtures.subject_for(user, account))

    user
  end

  test "without a pending marker, bounces back to /sign_in", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/sign_in"}}} = live(conn, ~p"/sign_in/mfa")
  end

  test "renders the OTP form after the password step set the marker", %{conn: conn} do
    user = mfa_user!()

    conn =
      post(conn, ~p"/sign_in", %{"user" => %{"email" => user.email, "password" => @password}})

    assert redirected_to(conn) == ~p"/sign_in/mfa"

    {:ok, lv, html} = live(conn, ~p"/sign_in/mfa")
    assert html =~ "Two-factor authentication"
    # Body intro (the "to finish signing in" suffix distinguishes it from the
    # controller's pending-MFA flash, which shares the leading phrase).
    assert html =~ "authenticator app to finish signing in"
    # Every sibling auth form disables on submit; this one must too, or a
    # double-click burns the one-time code.
    assert html =~ "phx-disable-with"

    # The lost-device path swaps the OTP input AND the intro copy — the
    # "authenticator app" line shouldn't linger in recovery mode.
    recovery_html = render_click(lv, "toggle_recovery", %{})
    assert recovery_html =~ "one-time recovery codes"
    refute recovery_html =~ "authenticator app to finish signing in"

    # Terminal escape for "lost device AND codes" shows only on the recovery
    # path (no admin reset exists, so it honestly points to support@).
    refute html =~ "Lost your recovery codes too?"
    assert recovery_html =~ "Lost your recovery codes too?"
    assert recovery_html =~ "support@emisar.dev"
  end
end
