defmodule EmisarWeb.MfaSetupLiveTest do
  @moduledoc """
  Covers the enforced-MFA enrollment interstitial: a non-compliant
  member of an enforcing account is forwarded here from any /app mount
  (the invite-accept flow's natural second step), enrolls in place,
  sees the recovery codes once, and continues to the dashboard.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Accounts, Auth, Mail, Users}

  setup %{conn: conn} do
    {_owner_conn, owner, account} = register_and_log_in(conn)
    owner_subject = owner_subject(owner, account)
    {_owner, _codes} = Fixtures.Users.enable_mfa!(Auth.generate_mfa_secret(), owner_subject)

    {:ok, account} =
      Accounts.update_account(
        account,
        %{settings: %{require_mfa: true}},
        owner_subject
      )

    user = Fixtures.Users.create_user()

    membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "viewer"
      )

    conn = build_conn() |> log_in_user(user)

    %{
      conn: conn,
      user: user,
      owner: owner,
      subject: Fixtures.Subjects.membership_subject(membership),
      account: account
    }
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

    html = begin_mfa_enrollment(lv)

    # The provisioning URI is rendered only after current-inbox proof — recover
    # the secret from it to play the authenticator's part.
    assert [_, encoded] = Regex.run(~r/secret=([A-Z2-7]+)/, html)
    secret = Base.decode32!(encoded, padding: false)
    otp = NimbleTOTP.verification_code(secret)

    # code_input's hidden field is client-owned, so render_submit can't set
    # it — drive the submit event directly (same as the profile MFA tests).
    html = render_hook(lv, "confirm_mfa", %{"mfa" => %{"otp" => otp}})

    assert html =~ "Save your recovery codes"
    # The codes are downloadable as a file, not just copyable.
    assert html =~ "Download .txt"

    # Continue is gated until the operator acknowledges saving the codes —
    # an MFA-required member who skips this can lock themselves out. The
    # acknowledgement checkbox starts unchecked.
    assert has_element?(lv, "button[disabled]", "Continue to dashboard")
    refute has_element?(lv, "input[type=checkbox][checked]")

    # A crafted socket event cannot bypass the disabled button.
    html = render_click(lv, "continue", %{})
    assert html =~ "Save your recovery codes before continuing."
    assert has_element?(lv, "button[disabled]", "Continue to dashboard")

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

  test "a wrong code is rejected inline at the form, not as a flash", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/app/mfa_setup")

    begin_mfa_enrollment(lv)

    render_hook(lv, "confirm_mfa", %{"mfa" => %{"otp" => "000000"}})

    assert has_element?(lv, "#mfa_form", "didn't match")
    refute has_element?(lv, "#flash-error", "didn't match")
  end

  test "an already-compliant member is sent straight to the dashboard", %{
    conn: conn,
    subject: subject
  } do
    secret = Auth.generate_mfa_secret()

    {:ok, _user, _codes} = Fixtures.Users.enroll_mfa(secret, subject)

    assert {:error, {:live_redirect, %{to: "/app"}}} = live(conn, ~p"/app/mfa_setup")
  end

  test "a stale setup view leaves when another session enables MFA", %{
    conn: conn,
    subject: subject
  } do
    {:ok, lv, _html} = live(conn, ~p"/app/mfa_setup")

    {_user, _codes} =
      Fixtures.Users.enable_mfa!(Auth.generate_mfa_secret(), subject)

    render_click(lv, "start_mfa", %{})

    assert_redirect(lv, "/app")
  end

  test "a concurrent enrollment completion exits instead of restarting email verification", %{
    conn: conn,
    subject: subject
  } do
    {:ok, lv, _html} = live(conn, ~p"/app/mfa_setup")
    html = begin_mfa_enrollment(lv)
    [_, encoded] = Regex.run(~r/secret=([A-Z2-7]+)/, html)
    pending_secret = Base.decode32!(encoded, padding: false)

    {_user, _codes} =
      Fixtures.Users.enable_mfa!(Auth.generate_mfa_secret(), subject)

    render_hook(lv, "confirm_mfa", %{
      "mfa" => %{"otp" => NimbleTOTP.verification_code(pending_secret)}
    })

    assert_redirect(lv, "/app")
  end

  test "a subject without account-view permission fails closed", %{
    user: user,
    account: account
  } do
    subject = Fixtures.Subjects.build_subject(user: user, account: account)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{current_user: user, current_account: account, current_subject: subject}
    }

    assert_raise EmisarWeb.NotFoundError, fn ->
      EmisarWeb.MfaSetupLive.mount(%{}, %{}, socket)
    end
  end

  test "the secret is minted only after email proof and the QR keeps it", %{conn: conn} do
    {:ok, lv, initial} = live(conn, ~p"/app/mfa_setup")

    refute initial =~ "secret="
    refute_received {:email, _}

    html = begin_mfa_enrollment(lv)

    assert [_, encoded] = Regex.run(~r/secret=([A-Z2-7]+)/, html)
    # The encoded secret is a real, decodable base32 TOTP secret (not a placeholder).
    assert {:ok, _secret} = Base.decode32(encoded, padding: false)

    # Re-rendering the SAME connected view keeps the same secret — minted once.
    assert [_, ^encoded] = Regex.run(~r/secret=([A-Z2-7]+)/, render(lv))
  end

  test "the disconnected render asks for an explicit email and sends nothing", %{
    conn: conn
  } do
    html = conn |> get(~p"/app/mfa_setup") |> html_response(200)

    assert html =~ "Email me a verification code"
    refute html =~ "secret="
    refute_received {:email, _}
  end

  test "crafted recovery-code events before enrollment are harmless", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/app/mfa_setup")

    html = render_click(lv, "toggle_codes_saved", %{})

    assert html =~ "Email me a verification code"
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
    html = begin_mfa_enrollment(lv)

    assert html =~ "<svg"
    # The dimensions MfaQr.svg/1 sets (width: 240) + EQRCode's module grid viewBox —
    # the fingerprint of the server-generated QR rather than a passthrough blob.
    assert html =~ ~s|width="240.0"|
    assert html =~ ~s|viewBox=|
  end

  test "a no-email member fails closed with actionable IdP guidance", %{account: account} do
    {:ok, user} = Users.provision_sso_user(%{full_name: "No Email"})

    Fixtures.Memberships.create_membership(
      account_id: account.id,
      user_id: user.id,
      role: "viewer"
    )

    conn = build_conn() |> log_in_user(user)
    {:ok, lv, _html} = live(conn, ~p"/app/mfa_setup")

    html = render_click(lv, "start_mfa", %{})

    assert html =~ "identity provider did not supply an email address"
    assert html =~ "Ask your administrator"
    refute html =~ "secret="
    refute_received {:email, _}
  end

  test "a mail-provider failure does not advance enforced enrollment", %{conn: conn} do
    Emisar.Config.put_override(:emisar, :mailer_deliver_error, {:error, {:failed, :boom}})
    {:ok, lv, _html} = live(conn, ~p"/app/mfa_setup")

    html = render_click(lv, "start_mfa", %{})

    assert html =~ "could not deliver the verification code"
    assert html =~ "contact support"
    assert html =~ "Email me a verification code"
    refute html =~ "Email verification code"
    refute html =~ "secret="
    refute_received {:email, _}
  end

  test "a suppressed current address does not claim or advance delivery", %{
    conn: conn,
    user: user
  } do
    assert {:ok, _suppression} = Mail.suppress(user.email, :hard_bounce, "bounce")
    {:ok, lv, _html} = live(conn, ~p"/app/mfa_setup")

    html = render_click(lv, "start_mfa", %{})

    assert html =~ "cannot deliver mail to your current address"
    assert html =~ "Contact support"
    assert html =~ "Email me a verification code"
    refute html =~ "Email verification code"
    refute html =~ "secret="
    refute_received {:email, _}
  end

  test "an account that stops requiring MFA mid-flow sends the member to the dashboard", %{
    conn: conn,
    owner: owner,
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
        owner_subject(owner, account)
      )

    assert {:error, {:live_redirect, %{to: "/app"}}} = live(conn, ~p"/app/mfa_setup")
  end

  describe ":ensure_account_compliant gate allow-paths" do
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
      subject: subject,
      account: account
    } do
      # the gate's exemptions (enrolled / SSO-satisfies /
      # un-required) match MfaSetupLive.mount's. For an ENROLLED member the two agree:
      # the gate lets them onto a normal page (no funnel) AND the setup page itself
      # short-circuits them to /app (nothing to enroll) — neither strands them.
      secret = Auth.generate_mfa_secret()

      {:ok, _user, _codes} = Fixtures.Users.enroll_mfa(secret, subject)

      # Gate: a normal page mounts (no redirect to setup).
      assert {:ok, _lv, _html} = live(conn, ~p"/app/#{account}/runners")
      # Page: setup short-circuits the already-compliant member straight to /app.
      assert {:error, {:live_redirect, %{to: "/app"}}} = live(conn, ~p"/app/mfa_setup")
    end
  end

  describe "magic-link sign-in funnels into enforced MFA setup" do
    test "a magic-link session with no second factor on a require_mfa account is funnelled to setup",
         %{
           user: user,
           account: account
         } do
      # a magic-link sign-in records no `mfa_verified_at` (the link
      # proves email control, not a second factor). So on a require_mfa account the
      # member is still un-enrolled, and the first /app mount's :ensure_account_compliant
      # gate funnels them into TOTP setup — the magic link is not an MFA bypass.
      magic_token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session(:user_token, magic_token)

      # The slugged dashboard's :ensure_account_compliant on_mount redirects an
      # un-enrolled member of a require_mfa account to /app/mfa_setup.
      assert {:error, {:redirect, %{to: "/app/mfa_setup"}}} =
               live(conn, ~p"/app/#{account}")
    end
  end

  describe "SSO precedes MFA on the enrollment interstitial" do
    setup %{account: account} do
      # require_sso + require_mfa, with an enabled connection so require_sso is live.
      Fixtures.SSO.create_identity_provider(account_id: account.id)
      Fixtures.Accounts.set_account_settings(account, %{require_sso: true, require_mfa: true})
      :ok
    end

    test "a magic-link member of a require_sso account is bounced to SSO before enrolling", %{
      conn: conn,
      account: account
    } do
      # A magic-link session must satisfy SSO BEFORE it can enroll a TOTP factor —
      # else it could set an attacker-chosen second factor without ever passing
      # the account's IdP. The :ensure_sso_compliant hook on the mfa_setup
      # live_session bounces it to the step-up shim.
      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/app/mfa_setup")
      assert to == ~p"/app/#{account}/sso_required"
    end
  end

  defp begin_mfa_enrollment(lv) do
    render_click(lv, "start_mfa", %{})
    assert_received {:email, email}
    [code] = Regex.run(~r/\d{6}/, email.text_body)

    render_hook(lv, "verify_mfa_enrollment_email", %{
      "mfa_enrollment" => %{"code" => code}
    })
  end
end
