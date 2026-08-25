defmodule EmisarWeb.MfaSetupLiveTest do
  @moduledoc """
  Covers the enforced-MFA interstitial: a non-compliant member is forwarded
  here from any /app mount, enrolls when needed, or proves an existing factor
  for this browser before continuing to the dashboard.
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
    user: user,
    account: account
  } do
    sibling_token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
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

    assert {:ok, enrolled, current_session} =
             Auth.fetch_user_and_token_by_session_token(get_session(conn, :user_token))

    assert current_session.mfa_enrollment_verified_at == enrolled.mfa_enabled_at

    assert {:ok, sibling_user, sibling_session} =
             Auth.fetch_user_and_token_by_session_token(sibling_token)

    assert sibling_user.id == enrolled.id
    assert sibling_session.mfa_enrollment_verified_at == nil

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

  test "an enrolled member verifies TOTP for only this browser", %{
    conn: conn,
    user: user,
    subject: subject
  } do
    secret = Auth.generate_mfa_secret()
    sibling_token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)

    {:ok, enrolled, _codes} = Fixtures.Users.enroll_mfa(secret, subject)

    {:ok, lv, html} = live(conn, ~p"/app/mfa_setup")

    assert html =~ "Verify this session"

    render_hook(lv, "verify_totp", %{"otp" => NimbleTOTP.verification_code(secret)})
    assert_redirect(lv, "/app")

    assert {:ok, current_user, current_session} =
             Auth.fetch_user_and_token_by_session_token(get_session(conn, :user_token))

    assert current_user.id == enrolled.id
    assert current_session.mfa_enrollment_verified_at == current_user.mfa_enabled_at

    assert {:ok, sibling_user, sibling_session} =
             Auth.fetch_user_and_token_by_session_token(sibling_token)

    assert sibling_user.id == enrolled.id
    assert sibling_session.mfa_enrollment_verified_at == nil
  end

  test "an enrolled member can use one recovery code for only this browser", %{
    conn: conn,
    user: user,
    subject: subject
  } do
    sibling_token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)

    {enrolled, [recovery_code | _]} =
      Fixtures.Users.enable_mfa!(Auth.generate_mfa_secret(), subject)

    {:ok, lv, _html} = live(conn, ~p"/app/mfa_setup")
    render_click(lv, "use_recovery")
    render_hook(lv, "verify_recovery", %{"code" => recovery_code})
    assert_redirect(lv, "/app")

    assert {:ok, current_user, current_session} =
             Auth.fetch_user_and_token_by_session_token(get_session(conn, :user_token))

    assert current_user.id == enrolled.id
    assert current_session.mfa_enrollment_verified_at == current_user.mfa_enabled_at

    assert {:ok, sibling_user, sibling_session} =
             Auth.fetch_user_and_token_by_session_token(sibling_token)

    assert sibling_user.id == enrolled.id
    assert sibling_session.mfa_enrollment_verified_at == nil

    assert Auth.verify_mfa_challenge(enrolled, {:recovery_code, recovery_code}) ==
             {:error, :invalid}
  end

  test "a stale setup view remounts into challenge when another session enables MFA", %{
    conn: conn,
    subject: subject
  } do
    {:ok, lv, _html} = live(conn, ~p"/app/mfa_setup")

    {_user, _codes} =
      Fixtures.Users.enable_mfa!(Auth.generate_mfa_secret(), subject)

    render_click(lv, "start_mfa", %{})

    assert_redirect(lv, "/app/mfa_setup")
    {:ok, _challenge, html} = live(conn, ~p"/app/mfa_setup")
    assert html =~ "Verify this session"
  end

  test "a concurrent enrollment completion remounts into challenge", %{
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

    assert_redirect(lv, "/app/mfa_setup")
    {:ok, _challenge, html} = live(conn, ~p"/app/mfa_setup")
    assert html =~ "Verify this session"
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

    test "require_mfa ON — an unproved member is redirected before profile", %{
      conn: conn,
      account: account
    } do
      assert {:error, {:redirect, %{to: "/app/mfa_setup"}}} =
               live(conn, ~p"/app/#{account}/settings/profile")
    end

    test "gate + setup page agree: enrollment without this session's proof is challenged", %{
      conn: conn,
      subject: subject,
      account: account
    } do
      secret = Auth.generate_mfa_secret()

      {:ok, _user, _codes} = Fixtures.Users.enroll_mfa(secret, subject)

      assert {:error, {:redirect, %{to: "/app/mfa_setup"}}} =
               live(conn, ~p"/app/#{account}/runners")

      assert {:error, {:redirect, %{to: "/app/mfa_setup"}}} =
               live(conn, ~p"/app/#{account}/settings/profile")

      assert {:ok, _lv, html} = live(conn, ~p"/app/mfa_setup")
      assert html =~ "Verify this session"
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

  test "provider-false SSO keeps its provenance while proving local TOTP", %{
    user: user,
    account: account,
    subject: subject
  } do
    {enrolled, [recovery_code | _]} =
      Fixtures.Users.enable_mfa!(Auth.generate_mfa_secret(), subject)

    provider =
      Fixtures.SSO.create_identity_provider(account_id: account.id, satisfies_mfa: false)

    identity =
      Fixtures.SSO.create_user_identity(%{
        account_id: account.id,
        provider_id: provider.id,
        user_id: user.id
      })

    Fixtures.Accounts.set_account_settings(account, %{require_sso: true, require_mfa: true})
    idp_verified_at = DateTime.utc_now()

    token =
      Fixtures.Auth.create_session_token!(enrolled, :sso, idp_verified_at, %{},
        user_identity_id: identity.id
      )

    conn =
      build_conn()
      |> init_test_session(%{})
      |> put_session(:user_token, token)

    {:ok, lv, html} = live(conn, ~p"/app/mfa_setup")
    assert html =~ "Verify this session"

    render_click(lv, "use_recovery")
    render_hook(lv, "verify_recovery", %{"code" => recovery_code})
    assert_redirect(lv, "/app")

    assert {:ok, current_user, session} = Auth.fetch_user_and_token_by_session_token(token)
    assert current_user.id == enrolled.id
    assert session.auth_method == :sso
    assert session.user_identity_id == identity.id
    assert session.mfa_verified_at == idp_verified_at
    assert session.mfa_enrollment_verified_at == current_user.mfa_enabled_at

    assert {:ok, _dashboard, _html} = live(conn, ~p"/app/#{account}")
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
    code = Fixtures.Auth.code_from_email(email)

    render_hook(lv, "verify_mfa_enrollment_email", %{
      "mfa_enrollment" => %{"code" => code}
    })
  end
end
