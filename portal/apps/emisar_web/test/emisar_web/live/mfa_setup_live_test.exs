defmodule EmisarWeb.MfaSetupLiveTest do
  @moduledoc """
  The workspace's MFA page (`/app/:slug/mfa_setup`, plan §3 "MFA"): a Member
  of a workspace that requires MFA is forwarded here from every page; without a
  factor it enrolls, with one it proves the factor for this browser. Enrollment
  needs a fresh proof of the Member's own credential — an emailed code to a
  verified address, or a new sign-in at the workspace's identity provider for
  an SSO-only Member — and session age alone never counts.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Accounts, Auth, Mail, Repo}

  # The IdP's protocol layer, stubbed as `EmisarWeb.SSOControllerTest` does:
  # the callback's verified claims come from `params["_claims"]`.
  defmodule StubOIDC do
    @behaviour Emisar.SSO.OIDC

    @impl Emisar.SSO.OIDC
    def begin_authorization(_provider, _opts) do
      {:ok, %{authorize_url: "https://idp.test/auth", state: "s", nonce: "n", pkce_verifier: "v"}}
    end

    @impl Emisar.SSO.OIDC
    def verify_callback(_provider, %{"_claims" => claims}, _stashed) do
      claims = Map.update(claims, "auth_time", nil, &String.to_integer/1)
      {:ok, %{identifier: claims["sub"], claims: claims}}
    end
  end

  setup %{conn: conn} do
    {owner_conn, owner, account} = register_and_log_in(conn)
    owner_token = session_token(owner_conn, account)
    owner_subject = Fixtures.Subjects.subject_for(owner, session: owner_token)

    {:ok, owner, _codes} =
      Fixtures.Memberships.enroll_mfa(Auth.generate_mfa_secret(), owner_subject,
        session_token: owner_token
      )

    owner_subject = Fixtures.Subjects.subject_for(owner, session: owner_token)

    {:ok, account} =
      Accounts.update_account(account, %{settings: %{require_mfa: true}}, owner_subject)

    member = Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")
    conn = log_in_member(build_conn(), member)

    %{
      conn: conn,
      member: member,
      owner_subject: owner_subject,
      subject: Fixtures.Subjects.subject_for(member),
      account: account
    }
  end

  defp setup_path(account), do: ~p"/app/#{account}/mfa_setup"

  test "a non-compliant Member is forwarded from the workspace to its MFA page", %{
    conn: conn,
    account: account
  } do
    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/app/#{account}")
    assert to == setup_path(account)
  end

  test "revocation between the page GET and the socket connection goes to the workspace sign-in",
       %{conn: conn, member: member, account: account, owner_subject: owner_subject} do
    shown = get(conn, setup_path(account))
    assert html_response(shown, 200) =~ "authentication"
    assert Accounts.end_all_sessions_for(member, owner_subject) == :ok

    assert {:error, {:redirect, %{to: to}}} = live(shown)
    assert to == ~p"/app/#{account}/sign_in"
  end

  for event <- [
        "start_mfa",
        "resend_mfa_enrollment_email",
        "verify_mfa_enrollment_email",
        "verify_totp",
        "verify_recovery"
      ] do
    @event event
    test "#{event} on a revoked mounted page goes back to the workspace", %{
      conn: conn,
      member: member,
      account: account,
      subject: subject
    } do
      if @event in ["verify_totp", "verify_recovery"] do
        Fixtures.Memberships.enable_mfa!(Auth.generate_mfa_secret(), subject)
      end

      {:ok, lv, _html} = live(conn, setup_path(account))

      params =
        case @event do
          event when event in ["resend_mfa_enrollment_email", "verify_mfa_enrollment_email"] ->
            render_click(lv, "start_mfa", %{})
            assert_received {:email, email}
            %{"mfa_enrollment" => %{"code" => Fixtures.Auth.code_from_email(email)}}

          "verify_totp" ->
            %{"otp" => "000000"}

          "verify_recovery" ->
            %{"code" => "irrelevant-after-revocation"}

          _ ->
            %{}
        end

      before = Repo.reload!(member)
      Fixtures.Auth.delete_session_token!(session_token(conn, account))
      render_hook(lv, @event, params)
      flash = assert_redirect(lv, ~p"/app/#{account}")
      assert flash["error"] == EmisarWeb.MfaErrors.message(:session_not_found)
      assert Repo.reload!(member) == before
      refute_received {:email, _}
    end
  end

  test "enrolls in place: scan, confirm, save recovery codes, continue", %{
    conn: conn,
    member: member,
    account: account
  } do
    sibling_token = Fixtures.Auth.create_session_token!(member)
    {:ok, lv, html} = live(conn, setup_path(account))

    assert html =~ account.name
    assert html =~ "Set up an authenticator app to continue."

    html = begin_mfa_enrollment(lv)

    # The manual setup key is rendered only after current-inbox proof — recover
    # the secret from it to play the authenticator's part.
    assert [_, encoded] = Regex.run(~r/data-copy-text="([A-Z2-7]+)"/, html)
    secret = Base.decode32!(encoded, padding: false)
    html = submit_concurrent_mfa_enrollment(lv, secret)

    assert html =~ "Save your recovery codes"
    # The codes are downloadable as a file, not just copyable.
    assert html =~ "Download .txt"

    assert {:ok, %{membership: enrolled} = current_session} =
             Auth.fetch_session_by_token(session_token(conn, account), account.id)

    assert enrolled.id == member.id
    assert current_session.mfa_enrollment_verified_at == enrolled.mfa_enabled_at
    assigns = :sys.get_state(lv.pid).socket.assigns

    assert assigns.current_auth.mfa_enrollment_verified_at ==
             current_session.mfa_enrollment_verified_at

    assert assigns.current_subject.mfa

    # Another session of the same Member did not prove the new factor.
    assert {:ok, sibling_session} = Auth.fetch_session_by_token(sibling_token, account.id)
    assert sibling_session.mfa_enrollment_verified_at == nil

    # Continue is gated until the operator acknowledges saving the codes.
    assert has_element?(lv, "button[disabled]", "Continue")
    refute has_element?(lv, "input[type=checkbox][checked]")

    # A crafted socket event cannot bypass the disabled button.
    html = render_click(lv, "continue", %{})
    assert html =~ "Save your recovery codes before continuing."
    assert has_element?(lv, "button[disabled]", "Continue")

    html = render_click(lv, "toggle_codes_saved", %{})
    assert html =~ ~r/<input[^>]*type="checkbox"[^>]*checked/
    refute has_element?(lv, "button[disabled]", "Continue")

    assert {:error, {:live_redirect, %{to: to}}} =
             lv |> element("button", "Continue") |> render_click()

    assert to == ~p"/app/#{account}"
  end

  test "the required-MFA exit signs out through DELETE and ends this session", %{
    conn: conn,
    account: account
  } do
    token = session_token(conn, account)
    {:ok, lv, _html} = live(conn, setup_path(account))

    assert has_element?(lv, "a[href='/sign_out'][data-method=delete]", "Sign out")

    signed_out = delete(conn, ~p"/sign_out")

    assert redirected_to(signed_out) == "/"
    refute get_session(signed_out, :sessions)
    assert Auth.fetch_session_by_token(token, account.id) == {:error, :not_found}
  end

  test "resending the enrollment code confirms delivery and keeps the email step", %{
    conn: conn,
    member: member,
    account: account
  } do
    {:ok, lv, _html} = live(conn, setup_path(account))
    render_click(lv, "start_mfa", %{})
    assert_received {:email, _first_email}

    html = lv |> element("button", "Resend code") |> render_click()

    assert html =~ "We sent a new verification code to #{member.email}."
    assert has_element?(lv, "#mfa_enrollment_email_form")
    refute has_element?(lv, "#mfa_form")
    assert_received {:email, email}
    code = Fixtures.Auth.code_from_email(email)

    render_submit(lv, "verify_mfa_enrollment_email", %{"mfa_enrollment" => %{"code" => code}})

    assert has_element?(lv, "#mfa_form")
    refute has_element?(lv, "#mfa_enrollment_email_form")
  end

  test "a wrong code is rejected inline at the form, not as a flash", %{
    conn: conn,
    account: account
  } do
    {:ok, lv, _html} = live(conn, setup_path(account))
    begin_mfa_enrollment(lv)

    render_hook(lv, "confirm_mfa", %{"mfa" => %{"otp" => "000000"}})

    assert has_element?(lv, "#mfa_form", "didn't match")
    refute has_element?(lv, "#flash-error", "didn't match")
    assert_push_event(lv, "code:reset", %{id: "mfa-otp"})
  end

  test "an enrolled Member verifies TOTP for only this browser", %{
    conn: conn,
    member: member,
    account: account,
    subject: subject
  } do
    secret = Auth.generate_mfa_secret()
    sibling_token = Fixtures.Auth.create_session_token!(member)
    {enrolled, _codes} = Fixtures.Memberships.enable_mfa!(secret, subject)

    {:ok, lv, html} = live(conn, setup_path(account))
    assert html =~ "Enter an authenticator or recovery code to continue."

    render_hook(lv, "verify_totp", %{"otp" => Fixtures.Auth.totp_code(secret)})
    assert_redirect(lv, ~p"/app/#{account}")

    assert {:ok, current_session} =
             Auth.fetch_session_by_token(session_token(conn, account), account.id)

    assert current_session.membership_id == enrolled.id
    assert current_session.mfa_enrollment_verified_at == Repo.reload!(enrolled).mfa_enabled_at

    assert {:ok, sibling_session} = Auth.fetch_session_by_token(sibling_token, account.id)
    assert sibling_session.mfa_enrollment_verified_at == nil
  end

  test "an enrolled Member can use one recovery code for only this browser", %{
    conn: conn,
    member: member,
    account: account,
    subject: subject
  } do
    sibling_token = Fixtures.Auth.create_session_token!(member)

    {enrolled, [recovery_code | _]} =
      Fixtures.Memberships.enable_mfa!(Auth.generate_mfa_secret(), subject)

    {:ok, lv, _html} = live(conn, setup_path(account))
    render_click(lv, "use_recovery")
    render_hook(lv, "verify_recovery", %{"code" => recovery_code})
    assert_redirect(lv, ~p"/app/#{account}")

    assert {:ok, current_session} =
             Auth.fetch_session_by_token(session_token(conn, account), account.id)

    assert current_session.mfa_enrollment_verified_at == Repo.reload!(enrolled).mfa_enabled_at

    assert {:ok, sibling_session} = Auth.fetch_session_by_token(sibling_token, account.id)
    assert sibling_session.mfa_enrollment_verified_at == nil

    assert Auth.verify_mfa_challenge(enrolled.id, {:recovery_code, recovery_code}) ==
             {:error, :invalid}
  end

  test "a stale setup view remounts into the challenge when another session enrolls", %{
    conn: conn,
    account: account,
    subject: subject
  } do
    {:ok, lv, _html} = live(conn, setup_path(account))
    {_member, _codes} = Fixtures.Memberships.enable_mfa!(Auth.generate_mfa_secret(), subject)

    assert {:error, {:live_redirect, %{to: to}}} = render_click(lv, "start_mfa", %{})
    assert to == setup_path(account)

    {:ok, _challenge, html} = live(conn, setup_path(account))
    assert html =~ "Enter an authenticator or recovery code to continue."
  end

  test "a concurrent enrollment completion remounts into the challenge", %{
    conn: conn,
    account: account,
    subject: subject
  } do
    {:ok, lv, _html} = live(conn, setup_path(account))
    html = begin_mfa_enrollment(lv)
    [_, encoded] = Regex.run(~r/data-copy-text="([A-Z2-7]+)"/, html)
    pending_secret = Base.decode32!(encoded, padding: false)

    {_member, _codes} = Fixtures.Memberships.enable_mfa!(Auth.generate_mfa_secret(), subject)

    assert {:error, {:live_redirect, %{to: to}}} =
             submit_concurrent_mfa_enrollment(lv, pending_secret)

    assert to == setup_path(account)
    {:ok, _challenge, html} = live(conn, setup_path(account))
    assert html =~ "Enter an authenticator or recovery code to continue."
  end

  test "a subject without account-view permission fails closed", %{
    member: member,
    account: account
  } do
    subject = Fixtures.Subjects.build_subject(member: member, account: account)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, current_account: account, current_subject: subject}
    }

    assert_raise EmisarWeb.NotFoundError, fn ->
      EmisarWeb.UserAuth.on_mount(:assign_account_compliance, %{}, %{}, socket)
    end
  end

  test "the secret is minted only after email proof and the QR keeps it", %{
    conn: conn,
    account: account
  } do
    {:ok, lv, initial} = live(conn, setup_path(account))

    refute initial =~ "mfa-setup-key"
    refute_received {:email, _}

    html = begin_mfa_enrollment(lv)

    assert [_, encoded] = Regex.run(~r/data-copy-text="([A-Z2-7]+)"/, html)
    assert {:ok, _secret} = Base.decode32(encoded, padding: false)

    # Re-rendering the SAME connected view keeps the same secret — minted once.
    assert [_, ^encoded] = Regex.run(~r/data-copy-text="([A-Z2-7]+)"/, render(lv))
  end

  test "the disconnected render loads without sending anything", %{
    conn: conn,
    account: account
  } do
    html = conn |> get(setup_path(account)) |> html_response(200)

    assert html =~ "Loading"
    refute html =~ "mfa-setup-key"
    refute_received {:email, _}
  end

  test "a verified Member is offered the emailed code, and crafted events before it are harmless",
       %{conn: conn, account: account} do
    {:ok, lv, html} = live(conn, setup_path(account))
    assert html =~ "Email me a verification code"

    for {event, params} <- [
          {"toggle_codes_saved", %{}},
          {"confirm_mfa", %{"mfa" => %{"otp" => "123456"}}},
          {"verify_mfa_enrollment_email", %{"mfa_enrollment" => %{"code" => "ABCDEF"}}}
        ] do
      render_hook(lv, event, params)
      refute render(lv) =~ "mfa-setup-key"
    end

    refute_received {:email, _}
  end

  test "the QR is a server-generated SVG, never attacker-influenced markup (IL-16)", %{
    conn: conn,
    account: account
  } do
    {:ok, lv, _html} = live(conn, setup_path(account))
    html = begin_mfa_enrollment(lv)

    assert html =~ "<svg"
    assert html =~ ~s|width="240.0"|
    assert html =~ ~s|viewBox=|
  end

  test "an email-code session of a Member without a verified address cannot enroll", %{
    account: account
  } do
    member =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        role: "viewer",
        email_verified?: false
      )

    conn = log_in_member(build_conn(), member)
    {:ok, lv, html} = live(conn, setup_path(account))

    assert html =~ "We can&#39;t confirm it&#39;s you from this session"
    refute html =~ "Email me a verification code"
    refute html =~ "Verify with"

    # A crafted start sends nothing: there is no proved address to send to.
    html = render_click(lv, "start_mfa", %{})
    assert html =~ "We can&#39;t confirm it&#39;s you from this session"
    refute html =~ "mfa-setup-key"
    refute_received {:email, _}
  end

  test "a mail-provider failure does not advance enforced enrollment", %{
    conn: conn,
    account: account
  } do
    Emisar.Config.put_override(:emisar, :mailer_deliver_error, {:error, {:failed, :boom}})
    {:ok, lv, _html} = live(conn, setup_path(account))

    html = render_click(lv, "start_mfa", %{})

    assert html =~ "could not deliver the verification code"
    assert html =~ "contact support"
    assert html =~ "Email me a verification code"
    refute html =~ "mfa-setup-key"
    refute_received {:email, _}
  end

  test "a suppressed address does not claim or advance delivery", %{
    conn: conn,
    member: member,
    account: account
  } do
    assert {:ok, _suppression} = Mail.suppress(member.email, :hard_bounce, "bounce")
    {:ok, lv, _html} = live(conn, setup_path(account))

    html = render_click(lv, "start_mfa", %{})

    assert html =~ "cannot deliver mail to your address"
    assert html =~ "Contact support"
    assert html =~ "Email me a verification code"
    refute html =~ "mfa-setup-key"
    refute_received {:email, _}
  end

  test "a workspace that stops requiring MFA sends the Member to the workspace", %{
    conn: conn,
    owner_subject: owner_subject,
    account: account
  } do
    {:ok, _account} =
      Accounts.update_account(account, %{settings: %{require_mfa: false}}, owner_subject)

    assert {:error, {:live_redirect, %{to: to}}} = live(conn, setup_path(account))
    assert to == ~p"/app/#{account}"
  end

  describe "the compliance gate" do
    test "a workspace without require_mfa mounts normally for an unenrolled Member", %{
      conn: conn
    } do
      open = Fixtures.Accounts.create_account(%{name: "Open Team"})
      open_member = Fixtures.Memberships.create_membership(account_id: open.id, role: "owner")

      conn = log_in_member(conn, open_member)
      assert {:ok, _lv, _html} = live(conn, ~p"/app/#{open}/runners")
    end

    test "an unproved Member is sent to the MFA page from every page, profile included", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      for path <- [~p"/app/#{account}/runners", ~p"/app/#{account}/settings/profile"] do
        assert {:error, {:redirect, %{to: to}}} = live(conn, path)
        assert to == setup_path(account)
      end

      # Enrolled elsewhere, this session has still not proved the factor.
      {:ok, _member, _codes} =
        Fixtures.Memberships.enroll_mfa(Auth.generate_mfa_secret(), subject)

      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/app/#{account}/runners")
      assert to == setup_path(account)
      assert {:ok, _lv, html} = live(conn, setup_path(account))
      assert html =~ "Enter an authenticator or recovery code to continue."
    end
  end

  test "an IdP that does not satisfy MFA keeps its SSO provenance while the session proves local TOTP",
       %{member: member, account: account, subject: subject} do
    Fixtures.Accounts.create_subscription(account, "team")

    {enrolled, [recovery_code | _]} =
      Fixtures.Memberships.enable_mfa!(Auth.generate_mfa_secret(), subject)

    provider =
      Fixtures.SSO.create_identity_provider(account_id: account.id, satisfies_mfa: false)

    identity = Fixtures.SSO.create_user_identity(provider_id: provider.id, membership: member)
    Fixtures.Accounts.set_account_settings(account, %{require_sso: true, require_mfa: true})

    conn =
      log_in_member(build_conn(), enrolled,
        auth_method: :sso,
        user_identity_id: identity.id,
        mfa: true
      )

    token = session_token(conn, account)
    {:ok, %{mfa_verified_at: idp_verified_at}} = Auth.fetch_session_by_token(token, account.id)

    {:ok, lv, html} = live(conn, setup_path(account))
    assert html =~ "Enter an authenticator or recovery code to continue."

    render_click(lv, "use_recovery")
    render_hook(lv, "verify_recovery", %{"code" => recovery_code})
    assert_redirect(lv, ~p"/app/#{account}")

    assert {:ok, session} = Auth.fetch_session_by_token(token, account.id)
    assert session.membership_id == enrolled.id
    assert session.auth_method == :sso
    assert session.user_identity_id == identity.id
    assert session.mfa_verified_at == idp_verified_at
    assert session.mfa_enrollment_verified_at == Repo.reload!(enrolled).mfa_enabled_at

    assert {:ok, _dashboard, _html} = live(conn, ~p"/app/#{account}")
  end

  test "SSO precedes MFA: an email-code session of a require_sso workspace never reaches enrollment",
       %{conn: conn, account: account} do
    Fixtures.Accounts.create_subscription(account, "team")
    Fixtures.SSO.create_identity_provider(account_id: account.id)
    Fixtures.Accounts.set_account_settings(account, %{require_sso: true, require_mfa: true})

    # The workspace gate drops the session the policy refuses before the page
    # could offer a factor, so no factor is ever set without passing the IdP.
    assert {:error, {:redirect, %{to: to}}} = live(conn, setup_path(account))
    assert to == ~p"/app/#{account}/sign_in"
  end

  describe "an SSO-only Member" do
    setup %{account: account} do
      Fixtures.Accounts.create_subscription(account, "team")
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id, name: "Acme IdP")

      member =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "operator",
          email_verified?: false
        )

      identity = Fixtures.SSO.create_user_identity(provider_id: provider.id, membership: member)

      conn =
        log_in_member(build_conn(), member, auth_method: :sso, user_identity_id: identity.id)

      %{sso_conn: conn, sso_member: member, identity: identity}
    end

    test "is offered its IdP, never the email code; session age alone yields no factor", %{
      sso_conn: conn,
      sso_member: member,
      account: account
    } do
      {:ok, lv, html} = live(conn, setup_path(account))

      assert has_element?(
               lv,
               ~s(a[href="#{setup_path(account)}/sso"][data-method="post"]),
               "Verify with Acme IdP"
             )

      refute html =~ "Email me a verification code"
      refute html =~ "mfa-setup-key"

      for {event, params} <- [
            {"start_mfa", %{}},
            {"confirm_mfa", %{"mfa" => %{"otp" => "123456"}}}
          ] do
        render_hook(lv, event, params)
      end

      refute render(lv) =~ "mfa-setup-key"
      assert is_nil(Repo.reload!(member).mfa_enabled_at)
      refute_received {:email, _}
    end

    test "enrolls after a fresh sign-in at its IdP", %{
      sso_conn: conn,
      sso_member: member,
      identity: identity,
      account: account
    } do
      Emisar.Config.put_override(:emisar, :sso_oidc_impl, StubOIDC)

      completed =
        conn
        |> post(~p"/app/#{account}/mfa_setup/sso")
        |> recycle()
        |> get(~p"/sign_in/sso/callback", %{
          "_claims" => %{
            "sub" => identity.provider_identifier,
            "auth_time" => System.system_time(:second)
          }
        })

      assert redirected_to(completed) == setup_path(account)

      # The proof lands this page straight on the authenticator step.
      {:ok, lv, _html} = live(recycle(completed), setup_path(account))
      html = render(lv)
      assert [_, encoded] = Regex.run(~r/data-copy-text="([A-Z2-7]+)"/, html)
      secret = Base.decode32!(encoded, padding: false)

      assert submit_concurrent_mfa_enrollment(lv, secret) =~ "Save your recovery codes"
      assert %DateTime{} = Repo.reload!(member).mfa_enabled_at
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

  # A real TOTP generated at the end of one 30-second window can expire before
  # the LiveView validates it. Retry only that exact rejection once; every code
  # still passes through the production verifier.
  defp submit_concurrent_mfa_enrollment(lv, secret) do
    html =
      render_hook(lv, "confirm_mfa", %{
        "mfa" => %{"otp" => Fixtures.Auth.totp_code(secret)}
      })

    case html do
      html when is_binary(html) ->
        if html =~ "That code didn" do
          render_hook(lv, "confirm_mfa", %{
            "mfa" => %{"otp" => Fixtures.Auth.totp_code(secret)}
          })
        else
          html
        end

      navigation ->
        navigation
    end
  end
end
