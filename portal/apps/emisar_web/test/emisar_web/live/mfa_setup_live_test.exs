defmodule EmisarWeb.MfaSetupLiveTest do
  @moduledoc """
  Covers the enforced-MFA enrollment interstitial: a non-compliant
  member of an enforcing account is forwarded here from any /app mount
  (the invite-accept flow's natural second step), enrolls in place,
  sees the recovery codes once, and continues to the dashboard.
  """
  use EmisarWeb.ConnCase, async: true

  alias Emisar.{Accounts, Auth}

  setup %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)

    {:ok, account} =
      Accounts.update_account(account, %{require_mfa: true}, owner_subject(user, account))

    %{conn: conn, user: user, account: account}
  end

  test "a non-compliant member is forwarded from /app to the setup step", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/app/mfa_setup"}}} = live(conn, ~p"/app")
  end

  test "enrolls in place: scan, confirm, save recovery codes, continue", %{
    conn: conn,
    account: account
  } do
    {:ok, lv, html} = live(conn, ~p"/app/mfa_setup")

    assert html =~ account.name
    assert html =~ "requires two-factor authentication"

    # The provisioning URI is rendered for the can't-scan path — recover
    # the secret from it to play the authenticator's part.
    assert [_, encoded] = Regex.run(~r/secret=([A-Z2-7]+)/, html)
    secret = Base.decode32!(encoded, padding: false)
    otp = NimbleTOTP.verification_code(secret)

    html =
      lv
      |> form("#mfa_form", mfa: %{otp: otp})
      |> render_submit()

    assert html =~ "Save your recovery codes"

    lv
    |> element("button", "Continue to dashboard")
    |> render_click()

    assert_redirect(lv, "/app")
  end

  test "a wrong code stays on the step with a flash", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/app/mfa_setup")

    html =
      lv
      |> form("#mfa_form", mfa: %{otp: "000000"})
      |> render_submit()

    assert html =~ "didn&#39;t match"
  end

  test "an already-compliant member is sent straight to the dashboard", %{
    conn: conn,
    user: user
  } do
    secret = Auth.generate_mfa_secret()
    {:ok, _user, _codes} = Auth.enable_mfa(user, secret, NimbleTOTP.verification_code(secret))

    assert {:error, {:live_redirect, %{to: "/app"}}} = live(conn, ~p"/app/mfa_setup")
  end
end
