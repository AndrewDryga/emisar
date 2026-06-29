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
      Accounts.update_account(
        account,
        %{settings: %{require_mfa: true}},
        owner_subject(user, account)
      )

    %{conn: conn, user: user, account: account}
  end

  test "a non-compliant member is forwarded from /app to the setup step", %{
    conn: conn,
    account: account
  } do
    assert {:error, {:redirect, %{to: "/app/mfa_setup"}}} = live(conn, ~p"/app/#{account}")
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
    # The codes are downloadable as a file, not just copyable.
    assert html =~ "Download .txt"

    # Continue is gated until the operator acknowledges saving the codes —
    # an MFA-required member who skips this can lock themselves out. The
    # acknowledgement checkbox starts unchecked.
    assert has_element?(lv, "button[disabled]", "Continue to dashboard")
    refute has_element?(lv, "input[type=checkbox][checked]")

    html = render_click(lv, "toggle_codes_saved", %{})
    # The <.checkbox checked={@codes_saved?}> reflects the toggled state, and
    # Continue un-gates.
    assert html =~ ~r/<input[^>]*type="checkbox"[^>]*checked/
    refute has_element?(lv, "button[disabled]", "Continue to dashboard")

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
    user: user,
    account: account
  } do
    secret = Auth.generate_mfa_secret()

    {:ok, _user, _codes} =
      Auth.enable_mfa(secret, NimbleTOTP.verification_code(secret), owner_subject(user, account))

    assert {:error, {:live_redirect, %{to: "/app"}}} = live(conn, ~p"/app/mfa_setup")
  end

  test "the secret is minted once on the connected mount and the QR matches it", %{conn: conn} do
    # the secret MUST be generated on the connected mount
    # (the static render runs in a separate process, so a QR generated there
    # would differ from the one the form verifies against). The connected render
    # carries a provisioning URI whose `secret=` is a real base32 secret, and a
    # re-render of the same connected view keeps that exact secret — it is not
    # re-minted on every render.
    {:ok, lv, html} = live(conn, ~p"/app/mfa_setup")

    assert [_, encoded] = Regex.run(~r/secret=([A-Z2-7]+)/, html)
    # The encoded secret is a real, decodable base32 TOTP secret (not a placeholder).
    assert {:ok, _secret} = Base.decode32(encoded, padding: false)

    # Re-rendering the SAME connected view keeps the same secret — minted once.
    assert [_, ^encoded] = Regex.run(~r/secret=([A-Z2-7]+)/, render(lv))
  end

  test "the disconnected (static) render shows the preparing placeholder, no secret yet", %{
    conn: conn
  } do
    # before the LiveSocket connects, the static mount runs
    # the `connected?(socket)` == false branch: no secret is minted (it can't be,
    # the dead render is a throwaway process) and the page shows the "preparing"
    # placeholder rather than a QR a user might scan into a code that can never
    # confirm. The plain GET is exactly that pre-connect render.
    html = conn |> get(~p"/app/mfa_setup") |> html_response(200)

    assert html =~ "Preparing your setup code"
    # No provisioning secret is leaked into the dead render.
    refute html =~ "secret="
  end

  test "the QR is a server-generated SVG, never attacker-influenced markup (IL-16)", %{conn: conn} do
    # the only `raw/1` on this page renders `MfaQr.svg/1`,
    # whose input is the server-minted provisioning URI (issuer + the operator's
    # own email + a server-generated secret) — never runner/LLM/operator-supplied
    # content. The rendered QR is the EQRCode inline <svg>, so the `raw` is safe by
    # source: assert the page carries that server-built SVG (its distinctive 240px
    # canvas + QR viewBox), not arbitrary markup.
    {:ok, lv, _html} = live(conn, ~p"/app/mfa_setup")
    html = render(lv)

    assert html =~ "<svg"
    # The dimensions MfaQr.svg/1 sets (width: 240) + EQRCode's module grid viewBox —
    # the fingerprint of the server-generated QR rather than a passthrough blob.
    assert html =~ ~s|width="240.0"|
    assert html =~ ~s|viewBox=|
  end

  test "an account that stops requiring MFA mid-flow sends the member to the dashboard", %{
    conn: conn,
    user: user,
    account: account
  } do
    # the interstitial exists only to enforce `require_mfa`.
    # If the account drops the requirement while a member sits on this page, a
    # remount must NOT strand them in enrollment: the mount's first cond branch
    # (`not account.require_mfa`) sends them straight to /app.
    {:ok, _account} =
      Accounts.update_account(
        account,
        %{settings: %{require_mfa: false}},
        owner_subject(user, account)
      )

    assert {:error, {:live_redirect, %{to: "/app"}}} = live(conn, ~p"/app/mfa_setup")
  end

  describe ":ensure_mfa_compliant gate allow-paths" do
    test "require_mfa OFF — an un-enrolled member mounts a slugged page normally", %{
      conn: conn,
      user: user
    } do
      # the gate only funnels when the account enforces MFA.
      # A member who hasn't enrolled, mounting a NON-enforcing account's page, takes
      # the `not account.require_mfa` cond branch and continues — no detour to setup.
      no_mfa = Fixtures.Accounts.create_account(%{name: "Open Team"})

      _ =
        Fixtures.Memberships.create_membership(
          account_id: no_mfa.id,
          user_id: user.id,
          role: "owner"
        )

      assert {:ok, _lv, _html} = live(conn, ~p"/app/#{no_mfa}/runners")
    end

    test "require_mfa ON — an un-enrolled member can still reach the profile page to enroll", %{
      conn: conn,
      account: account
    } do
      # the profile page is the gate's one exception
      # (`socket.view == EmisarWeb.ProfileLive` → continue): an un-enrolled member of
      # a require_mfa account must be able to LOAD it, since the voluntary MFA setup UI
      # lives there. Every OTHER page funnels to /app/mfa_setup; profile does not.
      assert {:ok, _lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
    end

    test "gate + setup page agree: an enrolled member is exempt from both", %{
      conn: conn,
      user: user,
      account: account
    } do
      # the gate's exemptions (enrolled / SSO-satisfies /
      # un-required) match MfaSetupLive.mount's. For an ENROLLED member the two agree:
      # the gate lets them onto a normal page (no funnel) AND the setup page itself
      # short-circuits them to /app (nothing to enroll) — neither strands them.
      secret = Auth.generate_mfa_secret()

      {:ok, _user, _codes} =
        Auth.enable_mfa(
          secret,
          NimbleTOTP.verification_code(secret),
          owner_subject(user, account)
        )

      # Gate: a normal page mounts (no redirect to setup).
      assert {:ok, _lv, _html} = live(conn, ~p"/app/#{account}/runners")
      # Page: setup short-circuits the already-compliant member straight to /app.
      assert {:error, {:live_redirect, %{to: "/app"}}} = live(conn, ~p"/app/mfa_setup")
    end
  end

  describe "magic-link sign-in funnels into enforced MFA setup" do
    test "a magic-link session (mfa: false) on a require_mfa account is funnelled to setup", %{
      user: user,
      account: account
    } do
      # a magic-link sign-in records `mfa: false` (the link
      # proves email control, not a second factor). So on a require_mfa account the
      # member is still un-enrolled, and the first /app mount's :ensure_mfa_compliant
      # gate funnels them into TOTP setup — the magic link is not an MFA bypass.
      magic_token = Auth.create_session_token!(user, :magic_link, false)

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session(:user_token, magic_token)

      # The slugged dashboard's :ensure_mfa_compliant on_mount redirects an
      # un-enrolled member of a require_mfa account to /app/mfa_setup.
      assert {:error, {:redirect, %{to: "/app/mfa_setup"}}} =
               live(conn, ~p"/app/#{account}")
    end
  end
end
