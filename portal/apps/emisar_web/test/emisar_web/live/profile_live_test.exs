defmodule EmisarWeb.ProfileLiveTest do
  @moduledoc """
  Profile (plan §3 "Profile"): three sections, all about this Member in this
  workspace — its name (the email is shown, not editable: to change an address,
  an administrator invites the new one), its multi-factor authentication, and
  its own active sessions. Nothing here reaches another workspace or another
  Member.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Auth

  describe "the Profile section" do
    setup %{conn: conn} do
      {conn, owner, account} = register_and_log_in(conn)
      %{conn: conn, owner: owner, account: account}
    end

    test "shows the name and a read-only email, with how to change an address", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/profile")

      assert has_element?(lv, "#display-name", owner.display_name)
      assert has_element?(lv, "#email", owner.email)
      assert html =~ "ask a workspace administrator to invite the new address"
      refute has_element?(lv, "#email input")
      refute has_element?(lv, "#change-email")
      refute html =~ "Not verified"

      for section <- ~w(profile-details multi-factor-authentication sessions) do
        assert has_element?(lv, "##{section}")
      end
    end

    test "saves a new name for this Member only", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      # The same person in another workspace is another Member with its own name.
      elsewhere =
        Fixtures.Memberships.create_membership(email: owner.email, display_name: "Elsewhere")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      refute has_element?(lv, "#profile-form")
      lv |> element("#change-name", "Change name") |> render_click()

      html =
        lv
        |> form("#profile-form", %{"profile" => %{"display_name" => "Renamed Person"}})
        |> render_submit()

      assert html =~ "Name updated."
      assert has_element?(lv, "#display-name", "Renamed Person")
      refute has_element?(lv, "#profile-form")
      assert Emisar.Repo.reload!(owner).display_name == "Renamed Person"
      assert Emisar.Repo.reload!(elsewhere).display_name == "Elsewhere"
    end

    test "a draft survives validation and session paging; cancel discards it", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      lv |> element("#change-name") |> render_click()

      lv |> form("#profile-form", profile: %{display_name: "Draft Name"}) |> render_change()
      render_patch(lv, ~p"/app/#{account}/settings/profile?cursor=invalid")
      assert has_element?(lv, "#profile_display_name[value='Draft Name']")

      lv |> element("#profile-form button", "Cancel") |> render_click()

      refute has_element?(lv, "#profile-form")
      assert Emisar.Repo.reload!(owner).display_name == owner.display_name
      lv |> element("#change-name") |> render_click()
      assert has_element?(lv, "#profile_display_name[value='#{owner.display_name}']")
    end

    test "an invalid name keeps the editor open with a field error", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      lv |> element("#change-name") |> render_click()
      draft = String.duplicate("x", 256)

      lv |> form("#profile-form", profile: %{display_name: draft}) |> render_submit()

      assert has_element?(lv, "#profile-form", "should be at most 255 character(s)")
      assert has_element?(lv, "#profile_display_name[value='#{draft}']")
      assert Emisar.Repo.reload!(owner).display_name == owner.display_name
    end

    test "a save after the Member is removed goes back to the workspace", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      lv |> element("#change-name") |> render_click()
      Fixtures.Memberships.mark_membership_as_deleted(owner)

      lv
      |> form("#profile-form", %{"profile" => %{"display_name" => "Unsaved Name"}})
      |> render_submit()

      flash = assert_redirect(lv, ~p"/app/#{account}")
      assert flash["error"] == EmisarWeb.MfaErrors.message(:session_not_found)
      assert Emisar.Repo.reload!(owner).display_name == owner.display_name
    end

    test "a directory-managed name is read-only here", %{account: account} do
      Fixtures.Accounts.create_subscription(account, "enterprise")

      provider =
        Fixtures.SSO.create_identity_provider(account_id: account.id)
        |> Fixtures.SSO.enable_scim()

      %{membership: member} =
        Fixtures.SSO.create_directory_member(provider, display_name: "Directory Name")

      {:ok, lv, _html} =
        live(log_in_member(build_conn(), member), ~p"/app/#{account}/settings/profile")

      assert has_element?(lv, "#display-name", "Directory Name")
      assert has_element?(lv, "#display-name", "Your identity provider manages this name.")
      refute has_element?(lv, "#change-name")

      render_click(lv, "edit_profile", %{})
      refute has_element?(lv, "#profile-form")

      render_submit(lv, "save_profile", %{"profile" => %{"display_name" => "Crafted"}})
      assert Emisar.Repo.reload!(member).display_name == "Directory Name"
    end

    test "an SSO-only Member's address is marked unverified", %{account: account} do
      member =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "operator",
          email_verified?: false
        )

      {:ok, lv, _html} =
        live(log_in_member(build_conn(), member), ~p"/app/#{account}/settings/profile")

      assert has_element?(lv, "#email", member.email)
      assert has_element?(lv, "#email", "Not verified")
    end
  end

  describe "sessions" do
    setup %{conn: conn} do
      {conn, owner, account} = register_and_log_in(conn)
      %{conn: conn, owner: owner, account: account}
    end

    test "lists sessions and revokes the selected one", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      # A second session for the same user (another device).
      _other_device = log_in_member(build_conn(), owner)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      html = render(lv)
      assert html =~ "This session"

      subject = browser_subject(conn, owner, account)
      {:ok, sessions, _meta} = Auth.list_sessions_for_member(nil, subject, page: [limit: 100])
      assert length(sessions) == 2

      html = render_click(lv, "revoke_other_sessions", %{})
      assert html =~ "Other sessions signed out."

      {:ok, sessions, _meta} = Auth.list_sessions_for_member(nil, subject, page: [limit: 100])
      assert length(sessions) == 1
    end

    test "lists each session and marks the current device", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      # A second device with recognizable metadata so its row renders distinctly
      # from the current session.
      _other =
        Fixtures.Auth.create_session_token!(owner, :magic_link, nil, %{
          ip_address: "198.51.100.4",
          user_agent: "Mozilla/5.0 (X11; Linux x86_64) Chrome/124.0"
        })

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/profile")

      # The current session carries the "This session" marker; the second device
      # renders its IP + parsed label in its own row. Rows order by recency, so
      # position isn't asserted — the marker, not the slot, orients the operator.
      assert html =~ "This session"
      assert html =~ "198.51.100.4"
      assert html =~ "Chrome 124.0 on Linux"
      assert has_element?(lv, "#active-sessions li", "Email code")
      assert has_element?(lv, "#active-sessions li", "Sign-in IP:")
      assert has_element?(lv, "#active-sessions time[data-format=absolute][data-tooltip-id]")
      refute has_element?(lv, "#active-sessions", "Last active")
      assert has_element?(lv, "#active-sessions li", "This session")

      subject = browser_subject(conn, owner, account)
      {:ok, sessions, _meta} = Auth.list_sessions_for_member(nil, subject, page: [limit: 100])
      assert length(sessions) == 2
    end

    test "shows the recorded sign-in method and honest missing metadata", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      identity = Fixtures.SSO.create_user_identity(provider_id: provider.id, membership: owner)
      Fixtures.Auth.create_session_token!(owner, :sso, nil, %{}, user_identity_id: identity.id)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      assert has_element?(lv, "#active-sessions li", "Single sign-on")
      assert has_element?(lv, "#active-sessions li", "Sign-in IP: Not recorded")
      assert has_element?(lv, "#active-sessions li", "Unknown device")
    end

    test "links separately to this user's agents in the current workspace", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      membership =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")

      {:ok, _raw, _key} =
        Emisar.ApiKeys.create_key(
          %{name: "Someone else's agent"},
          Fixtures.Subjects.subject_for(membership)
        )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      href = ~p"/app/#{account}/agents?#{[owner: owner.id]}"
      assert has_element?(lv, ~s(#sessions-help p + p a[href="#{href}"]), "Review your agents")

      {:ok, agents, _html} =
        lv |> element("#review-your-agents") |> render_click() |> follow_redirect(conn, href)

      assert has_element?(agents, "select[name=owner] option[selected]", "You")
      assert has_element?(agents, "a", "Clear filters")
      assert render(agents) =~ "No agents match these filters."
      refute render(agents) =~ "Someone else&#39;s agent"
    end

    test "does not offer Agents to a billing manager", %{account: account} do
      member =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "billing_manager")

      {:ok, lv, _html} =
        live(log_in_member(build_conn(), member), ~p"/app/#{account}/settings/profile")

      assert has_element?(lv, "#sessions-help", "Don't recognize a session?")
      refute has_element?(lv, "#review-your-agents")
    end

    test "the own-agents filter stays readable for a Member without email", %{account: account} do
      membership =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer", email: nil)

      conn = log_in_member(build_conn(), membership)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      href = ~p"/app/#{account}/agents?#{[owner: membership.id]}"

      {:ok, agents, _html} =
        lv |> element("#review-your-agents") |> render_click() |> follow_redirect(conn, href)

      assert has_element?(agents, "select[name=owner] option[selected]", "You")
      assert render(agents) =~ "No agents match these filters."
    end

    test "caps the page at 10 sessions and pages the rest", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      # 10 more devices on top of the current session — 11 total, one past a page.
      for n <- 1..10 do
        token =
          Fixtures.Auth.create_session_token!(owner, :magic_link, nil, %{
            ip_address: "203.0.113.#{n}",
            user_agent: "Mozilla/5.0 (X11; Linux x86_64) Chrome/124.0"
          })

        # Page two must contain another device, not this browser, whose row
        # deliberately has no self-revoke control.
        if n == 1 do
          Fixtures.Auth.backdate_session_token!(
            token,
            DateTime.add(DateTime.utc_now(), -1, :hour)
          )
        end
      end

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      # Page one holds exactly 10 rows and a pager that names the 11 total.
      assert rendered_session_rows(lv) == 10
      assert has_element?(lv, "#active-sessions-pager", "11")
      assert has_element?(lv, "#active-sessions-pager a", "Next")

      # Following Next patches to page two — the 11th session, and the way back.
      html = lv |> element("#active-sessions-pager a", "Next") |> render_click()
      assert rendered_session_rows(lv) == 1
      assert html =~ "Prev"

      subject = browser_subject(conn, owner, account)
      {:ok, sessions, _meta} = Auth.list_sessions_for_member(nil, subject, page: [limit: 100])
      oldest_session = List.last(sessions)

      html = lv |> element("#signout-session-#{oldest_session.id}-confirm") |> render_click()

      assert rendered_session_rows(lv) == 0
      assert html =~ "This page no longer has results."
      assert has_element?(lv, "#active-sessions-pager a", "Back to first page")

      lv |> element("#active-sessions-pager a", "Back to first page") |> render_click()
      assert rendered_session_rows(lv) == 10
    end

    test "a session with no user agent shows the unknown-device mark", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      # A session recorded without a User-Agent header — the row still has to
      # name a device class, and UserAgent owns what that is. A local fallback
      # here once answered `infrastructure.network`, putting a globe in a column
      # of device silhouettes while the drawing made for this case went unused.
      Fixtures.Auth.create_session_token!(owner, :magic_link, nil, %{
        ip_address: "198.51.100.7"
      })

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/profile")

      assert html =~ "Unknown device"
      assert html =~ "device.unknown"
      refute html =~ "infrastructure.network"
    end

    test "renders and revokes same-device sessions independently", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      user_agent = "Mozilla/5.0 (X11; Linux x86_64) Chrome/124.0"

      Fixtures.Auth.create_session_token!(owner, :magic_link, nil, %{
        ip_address: "203.0.113.10",
        user_agent: user_agent
      })

      Fixtures.Auth.create_session_token!(owner, :magic_link, nil, %{
        ip_address: "203.0.113.11",
        user_agent: user_agent
      })

      subject = browser_subject(conn, owner, account)
      {:ok, sessions, _meta} = Auth.list_sessions_for_member(nil, subject, page: [limit: 100])
      first_session = Enum.find(sessions, &(&1.ip_address == "203.0.113.10"))
      second_session = Enum.find(sessions, &(&1.ip_address == "203.0.113.11"))

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/profile")

      refute html =~ "2 sessions"
      assert has_element?(lv, "#active-sessions > li", "203.0.113.10")
      assert has_element?(lv, "#active-sessions > li", "203.0.113.11")

      html = render_click(lv, "revoke_session", %{"id" => first_session.id})

      assert html =~ "Session signed out."
      refute html =~ "203.0.113.10"
      assert html =~ "203.0.113.11"

      assert {:ok, remaining, _meta} =
               Auth.list_sessions_for_member(nil, subject, page: [limit: 100])

      refute Enum.any?(remaining, &(&1.id == first_session.id))
      assert Enum.any?(remaining, &(&1.id == second_session.id))
    end

    test "revoking one non-current session removes exactly that row", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      # A second device — the row we'll revoke. It's the one the caller's own
      # session token does NOT mark as current.
      Fixtures.Auth.create_session_token!(owner, :magic_link, nil, %{
        user_agent: "Mozilla/5.0 (X11; Linux x86_64) Chrome/124.0"
      })

      subject = browser_subject(conn, owner, account)

      {:ok, sessions, _meta} =
        Auth.list_sessions_for_member(Emisar.Crypto.hash(session_token(conn, account)), subject,
          page: [limit: 100]
        )

      other = Enum.find(sessions, &(not &1.current?))

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      assert render_click(lv, "revoke_session", %{"id" => other.id}) =~ "Session signed out."

      # Down to one — only the current device remains.
      {:ok, remaining, _meta} = Auth.list_sessions_for_member(nil, subject, page: [limit: 100])
      assert length(remaining) == 1
      refute Enum.any?(remaining, &(&1.id == other.id))
    end

    test "the current device row offers no Revoke control", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      # Two devices: one current, one other. The other carries a sign-out control;
      # the current device must not (you can't sign yourself out from here —
      # that's "sign out everywhere else").
      Fixtures.Auth.create_session_token!(owner, :magic_link, nil, %{
        user_agent: "Mozilla/5.0 (X11; Linux x86_64) Chrome/124.0"
      })

      subject = browser_subject(conn, owner, account)

      {:ok, sessions, _meta} =
        Auth.list_sessions_for_member(Emisar.Crypto.hash(session_token(conn, account)), subject,
          page: [limit: 100]
        )

      other = Enum.find(sessions, &(not &1.current?))
      current = Enum.find(sessions, & &1.current?)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      assert has_element?(lv, "#signout-session-#{other.id}")

      refute has_element?(lv, "#signout-session-#{current.id}")
    end

    test "revoke_other_sessions with nothing to revoke says so", %{conn: conn, account: account} do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      assert render_click(lv, "revoke_other_sessions", %{}) =~ "No other sessions to sign out."
    end

    test "large session lists stay bounded in the context and on the page", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      # 100 more sessions (register_and_log_in already created one) → 101 total.
      for _ <- 1..100, do: Fixtures.Auth.create_session_token!(owner, :magic_link, nil)

      subject = browser_subject(conn, owner, account)
      {:ok, sessions, _meta} = Auth.list_sessions_for_member(nil, subject, page: [limit: 100])
      assert length(sessions) == 100

      # The page renders only ten while exposing the total and bulk action.
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/profile")
      assert rendered_session_rows(lv) == 10
      assert has_element?(lv, "#active-sessions-pager", "101")
      assert html =~ "Sign out everywhere else"
    end

    test "the disconnected (dead) render reads no session metadata", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      # IL-18: the session list is the only DB read on this page, gated behind
      # connected?/1 — so the dead render a plain GET produces must not include
      # session rows, even though a real session exists. A second device is seeded
      # so "no rows on the dead render" is meaningful.
      _other =
        Fixtures.Auth.create_session_token!(owner, :magic_link, nil, %{
          ip_address: "203.0.113.9",
          user_agent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15) Safari/17.0"
        })

      dead = conn |> get(~p"/app/#{account}/settings/profile") |> html_response(200)

      # The seeded device's metadata is NOT read on the dead pass.
      assert dead =~ "Loading sessions"
      assert dead =~ "Loading MFA settings"
      refute dead =~ "203.0.113.9"
      refute dead =~ "This session"
    end

    test "revoking a session removed after mount refreshes the displayed list", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      token = Fixtures.Auth.create_session_token!(owner, :magic_link, nil)
      subject = browser_subject(conn, owner, account)
      current_digest = Emisar.Crypto.hash(session_token(conn, account))
      {:ok, sessions, _meta} = Auth.list_sessions_for_member(current_digest, subject)
      other = Enum.find(sessions, &(not &1.current?))
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      assert has_element?(lv, "#sessions-#{other.id}")

      Fixtures.Auth.delete_session_token!(token)

      assert render_click(lv, "revoke_session", %{"id" => other.id}) =~
               "This session has already ended."

      refute has_element?(lv, "#sessions-#{other.id}")
      assert has_element?(lv, "#active-sessions", "This session")
    end

    test "the rendered session rows never surface the raw token (only id + metadata)", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      # A second session minted with a recognizable device (the metadata DOES
      # render) — and we keep the raw token it returns. The token is stored
      # hashed (UserToken.token holds the digest); neither the raw token nor its
      # digest may ever reach the rendered rows — only id + inserted_at + the
      # ip/user-agent metadata.
      raw_token =
        Fixtures.Auth.create_session_token!(owner, :magic_link, nil, %{
          ip_address: "203.0.113.7",
          user_agent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15) Firefox/126.0"
        })

      digest = Emisar.Crypto.hash(raw_token)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/profile")

      # The row renders from metadata, so the device + IP are visible…
      assert html =~ "Firefox 126.0 on Mac"
      assert html =~ "203.0.113.7"

      # …but the credential itself never is — not the raw token, not its digest
      # (the digest is binary, so check both its base16 + base64 encodings to be
      # sure no accidental serialization leaks it).
      refute html =~ raw_token
      refute html =~ Base.encode16(digest, case: :lower)
      refute html =~ Base.encode64(digest)
    end
  end

  describe "Active sessions belong to this Member" do
    test "another Member's sessions, here or in another workspace, are never listed or revoked",
         %{conn: conn} do
      {conn, owner, account} = register_and_log_in(conn)
      teammate = Fixtures.Memberships.create_membership(account_id: account.id)
      elsewhere = Fixtures.Memberships.create_membership(email: owner.email)

      teammate_token =
        Fixtures.Auth.create_session_token!(teammate, :magic_link, nil, %{
          ip_address: "203.0.113.21"
        })

      Fixtures.Auth.create_session_token!(elsewhere, :magic_link, nil, %{
        ip_address: "203.0.113.22"
      })

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      assert rendered_session_rows(lv) == 1
      refute render(lv) =~ "203.0.113.21"
      refute render(lv) =~ "203.0.113.22"

      teammate_row =
        teammate_token
        |> Emisar.Crypto.hash()
        |> Emisar.Auth.UserToken.Query.by_token_digest()
        |> Emisar.Repo.one!()

      assert render_click(lv, "revoke_session", %{"id" => teammate_row.id}) =~
               "This session has already ended."

      assert {:ok, _live} = Auth.fetch_session_by_token(teammate_token, account.id)
    end
  end

  describe "how a Member proves itself to enroll MFA" do
    test "an SSO-only Member is sent to its identity provider, never the email code", %{
      conn: conn
    } do
      {_conn, _owner, account} = register_and_log_in(conn, %{account: %{plan: "team"}})

      provider =
        Fixtures.SSO.create_identity_provider(account_id: account.id, name: "Acme Okta")

      member =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "operator",
          email_verified?: false
        )

      identity = Fixtures.SSO.create_user_identity(provider_id: provider.id, membership: member)

      conn = log_in_member(build_conn(), member, auth_method: :sso, user_identity_id: identity.id)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      assert has_element?(
               lv,
               ~s(#verify-with-sso[href="#{~p"/app/#{account}/mfa_setup/sso"}"][data-method="post"]),
               "Verify with Acme Okta"
             )

      refute has_element?(lv, "button[phx-click=start_mfa]")

      # A crafted start finds no address to prove and sends nothing.
      render_click(lv, "start_mfa", %{})
      refute render(lv) =~ "mfa-setup-key"
      refute_received {:email, _}
    end

    test "an email-code session without a verified address is told why it cannot enroll", %{
      conn: conn
    } do
      {_conn, _owner, account} = register_and_log_in(conn)

      member =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "operator",
          email_verified?: false
        )

      {:ok, lv, html} =
        live(log_in_member(build_conn(), member), ~p"/app/#{account}/settings/profile")

      assert html =~ "Neither is available from this session"
      refute has_element?(lv, "button[phx-click=start_mfa]")
      refute has_element?(lv, "#verify-with-sso")
    end
  end

  describe "MFA lifecycle" do
    setup %{conn: conn} do
      {conn, owner, account} = register_and_log_in(conn)
      %{conn: conn, owner: owner, account: account}
    end

    for event <- [
          "start_mfa",
          "resend_mfa_enrollment_email",
          "verify_mfa_enrollment_email",
          "confirm_mfa",
          "disable_mfa",
          "regenerate_recovery_codes"
        ] do
      @event event
      @tag :mfa_session_recovery
      test "#{event} sends an expired mounted browser back to the workspace", %{
        conn: conn,
        owner: owner,
        account: account
      } do
        if @event in ["disable_mfa", "regenerate_recovery_codes"] do
          Fixtures.Memberships.enable_mfa!(
            Auth.generate_mfa_secret(),
            Fixtures.Subjects.subject_for(owner)
          )
        end

        {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

        params =
          case @event do
            "confirm_mfa" ->
              secret = lv |> begin_mfa_enrollment() |> mfa_secret_from()
              %{"mfa" => %{"otp" => Fixtures.Auth.totp_code(secret)}}

            event when event in ["resend_mfa_enrollment_email", "verify_mfa_enrollment_email"] ->
              render_click(lv, "start_mfa", %{})
              assert_received {:email, email}
              %{"mfa_enrollment" => %{"code" => Fixtures.Auth.code_from_email(email)}}

            "disable_mfa" ->
              %{"mfa_disable" => %{"code" => "irrelevant-after-expiry"}}

            "regenerate_recovery_codes" ->
              %{"mfa_recovery_regeneration" => %{"code" => "irrelevant-after-expiry"}}

            _ ->
              %{}
          end

        before = Emisar.Repo.reload!(owner)

        Fixtures.Auth.backdate_session_token!(
          session_token(conn, account),
          DateTime.add(DateTime.utc_now(), -61, :day)
        )

        render_hook(lv, @event, params)
        flash = assert_redirect(lv, ~p"/app/#{account}")
        assert flash["error"] == EmisarWeb.MfaErrors.message(:session_not_found)
        assert Emisar.Repo.reload!(owner) == before
        refute_received {:email, _}
      end
    end

    @tag :mfa_session_recovery
    test "refreshing MFA facts after browser expiry reauthenticates without crashing", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      Fixtures.Auth.backdate_session_token!(
        session_token(conn, account),
        DateTime.add(DateTime.utc_now(), -61, :day)
      )

      render_patch(lv, ~p"/app/#{account}/settings/profile?cursor=expired")
      assert_redirect(lv, ~p"/app/#{account}")
    end

    test "email proof → authenticator confirm enables MFA and shows recovery codes once", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      html = begin_mfa_enrollment(lv)
      assert html =~ "<svg"

      # The LV holds the secret server-side; read it back the way the
      # operator would — from the manual-entry fallback in the QR panel.
      secret = mfa_secret_from(html)

      html = submit_mfa_enrollment(lv, secret)

      assert html =~ "MFA enabled."
      assert html =~ "recovery codes"
      assert Emisar.Repo.reload!(owner).mfa_enabled_at

      {:ok, persisted} =
        Auth.fetch_session_by_token(session_token(conn, account), account.id)

      assigns = :sys.get_state(lv.pid).socket.assigns

      assert assigns.current_auth.mfa_enrollment_verified_at ==
               persisted.mfa_enrollment_verified_at

      assert assigns.current_subject.mfa

      # Codes are shown exactly once — the panel goes away on dismiss
      # (the enable flash still mentions them, so check the element).
      assert has_element?(lv, "#mfa-recovery-codes")
      refute has_element?(lv, "#multi-factor-authentication-help")

      # The voluntary reveal offers a file download too (matching the enforced
      # setup path) — a clipboard is too volatile for a lockout credential.
      assert html =~ ~s(download="emisar-recovery-codes.txt")

      # Once saved, the MFA-on view surfaces how many codes remain (a fresh 10,
      # so no low-count nudge).
      assert has_element?(lv, "#mfa-recovery-codes button[disabled]", "Done")
      render_click(lv, "dismiss_recovery_codes", %{})
      assert has_element?(lv, "#mfa-recovery-codes")
      render_click(lv, "toggle_codes_saved", %{})
      html = render_click(lv, "dismiss_recovery_codes", %{})
      refute has_element?(lv, "#mfa-recovery-codes")
      assert has_element?(lv, "#multi-factor-authentication", "10 recovery codes remaining")
      refute has_element?(lv, "#multi-factor-authentication-help")
      refute html =~ "Generate new codes before these run out."
    end

    test "mount and refresh send no enrollment mail; the explicit start reveals no secret", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/profile")

      refute html =~ "mfa-setup-key"
      assert has_element?(lv, "#multi-factor-authentication", "Not enabled")
      assert has_element?(lv, "#mfa-status > button[phx-click=start_mfa]", "Set up MFA")

      assert has_element?(
               lv,
               "aside#multi-factor-authentication-help",
               "We recommend enabling MFA to help protect your account in this workspace."
             )

      refute has_element?(lv, "#multi-factor-authentication > div", "recommend")
      refute html =~ "First verify your email"
      refute html =~ "Keep your recovery codes somewhere"
      refute html =~ "Email verification code"
      refute_received {:email, _}

      html = render_click(lv, "start_mfa", %{})

      assert html =~ "Email verification code"
      refute has_element?(lv, "#multi-factor-authentication-help")
      refute has_element?(lv, "#multi-factor-authentication", "Not enabled")
      refute has_element?(lv, "#mfa-status")
      refute html =~ "mfa-setup-key"
      assert_received {:email, _}

      render_click(lv, "cancel_mfa", %{})
      assert has_element?(lv, "#multi-factor-authentication-help", "We recommend enabling MFA")
    end

    test "a suppressed current address does not claim or advance delivery", %{
      conn: conn,
      account: account,
      owner: owner
    } do
      assert {:ok, _suppression} =
               Emisar.Mail.suppress(owner.email, :hard_bounce, "bounce")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      html = render_click(lv, "start_mfa", %{})

      assert html =~ "cannot deliver mail to your address"
      assert html =~ "Contact support"
      refute html =~ "Email verification code"
      refute html =~ "mfa-setup-key"
      refute_received {:email, _}
    end

    test "a wrong or out-of-sequence inbox code never reveals the authenticator secret", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      html =
        render_hook(lv, "verify_mfa_enrollment_email", %{
          "mfa_enrollment" => %{"code" => "000000"}
        })

      assert html =~ "Start MFA setup again."
      refute html =~ "mfa-setup-key"

      render_click(lv, "start_mfa", %{})
      assert_received {:email, _}

      html =
        render_hook(lv, "verify_mfa_enrollment_email", %{
          "mfa_enrollment" => %{"code" => "000000"}
        })

      assert html =~ "incorrect or expired"
      refute html =~ "mfa-setup-key"
      assert_push_event(lv, "code:reset", %{id: "mfa-enrollment-email-code"})
    end

    test "the enrollment QR is a server-rendered inline SVG, not a third-party image", %{
      conn: conn,
      account: account
    } do
      # The otpauth URI carries the TOTP secret, so it must never be handed to an
      # external QR-image service. EmisarWeb.MfaQr renders the code as an inline
      # SVG server-side; `raw/1` on that markup is the documented IL-16 exception
      # (server-generated, not untrusted input). Assert the SVG is inlined and no
      # external image/script is the QR source.
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      html = begin_mfa_enrollment(lv)

      # The QR is an inlined <svg> (EQRCode), with the manual-entry fallback key
      # present in the page…
      assert html =~ "<svg"
      assert html =~ "mfa-setup-key"
      refute html =~ "otpauth://totp/"
      # …and the secret-bearing URI is NEVER handed to a remote image: it isn't an
      # <img src=> at all, and no known QR-image service host appears.
      refute html =~ ~r/<img[^>]+otpauth/
      refute html =~ "chart.googleapis.com"
      refute html =~ "api.qrserver.com"
    end

    test "a low recovery-code count nudges to regenerate (amber)", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      # MFA on with only 2 codes left (8 burned down on lost-device sign-ins) —
      # tracked all along but never shown until now.
      owner
      |> Ecto.Changeset.change(
        mfa_enabled_at: DateTime.utc_now(),
        mfa_recovery_codes: ["digest-1", "digest-2"]
      )
      |> Emisar.Repo.update!()

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/profile")

      assert has_element?(lv, "#multi-factor-authentication", "2 recovery codes remaining")
      assert html =~ "Generate new codes before these run out."
    end

    test "a wrong OTP leaves MFA off with the error inline at the code input", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      begin_mfa_enrollment(lv)

      render_hook(lv, "confirm_mfa", %{"mfa" => %{"otp" => "000000"}})

      # The rejection renders inside the enrollment form (not a transient flash),
      # and the QR stays up so the operator can retry with the next code.
      assert lv |> element("#mfa_form") |> render() =~ "That code didn&#39;t match"
      assert has_element?(lv, "#mfa-otp")
      assert_push_event(lv, "code:reset", %{id: "mfa-otp"})
      refute Emisar.Repo.reload!(owner).mfa_enabled_at
    end

    test "a stale profile view refreshes when another session enables MFA", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      {_user, _codes} =
        Fixtures.Memberships.enable_mfa!(
          Auth.generate_mfa_secret(),
          Fixtures.Subjects.subject_for(owner)
        )

      render_click(lv, "start_mfa", %{})

      assert_redirect(lv, ~p"/app/#{account}/settings/profile")
    end

    test "a concurrent enrollment completion refreshes the profile MFA state", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      pending_secret = lv |> begin_mfa_enrollment() |> mfa_secret_from()

      {_user, _codes} =
        Fixtures.Memberships.enable_mfa!(
          Auth.generate_mfa_secret(),
          Fixtures.Subjects.subject_for(owner)
        )

      submit_concurrent_mfa_enrollment(lv, pending_secret)

      assert_redirect(lv, ~p"/app/#{account}/settings/profile")
    end

    test "a non-numeric OTP is rejected and MFA stays off", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      # Start the enable flow so a pending secret is stashed, then submit a
      # six-char *non-numeric* code. NimbleTOTP compares it against the
      # secret-derived digits and it can't match, so enrollment is refused.
      begin_mfa_enrollment(lv)

      html = render_hook(lv, "confirm_mfa", %{"mfa" => %{"otp" => "abc123"}})

      assert html =~ "That code didn&#39;t match"
      refute Emisar.Repo.reload!(owner).mfa_enabled_at
    end

    test "a code from a prior 30s bucket is rejected (no leeway)", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      html = begin_mfa_enrollment(lv)
      secret = mfa_secret_from(html)

      # Crypto.valid_totp? validates only against the CURRENT window with no
      # leeway, so a code minted two buckets back can never match the live one —
      # the offset is large enough that a window straddle can't make it collide.
      stale_otp =
        NimbleTOTP.verification_code(secret, time: System.os_time(:second) - 90)

      html = render_hook(lv, "confirm_mfa", %{"mfa" => %{"otp" => stale_otp}})

      assert html =~ "That code didn&#39;t match"
      refute Emisar.Repo.reload!(owner).mfa_enabled_at
    end

    test "dismissing the recovery-codes reveal hides them and they're not re-shown", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      secret = Auth.generate_mfa_secret()

      {_user, [proof_code | _]} =
        Fixtures.Memberships.enable_mfa!(secret, Fixtures.Subjects.subject_for(owner))

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      # Regenerate to reveal a fresh one-shot set, then dismiss it — the reveal
      # is gone and a fresh mount never re-renders the plaintext codes.
      render_click(lv, "start_regenerate_recovery_codes", %{})

      render_submit(lv, "regenerate_recovery_codes", %{
        "mfa_recovery_regeneration" => %{
          "code" => proof_code
        }
      })

      assert has_element?(lv, "#mfa-recovery-codes")

      # Codes are lowercase base32 (Crypto.mfa_recovery_code/0) — pull one out of
      # the reveal to prove it's gone after dismissal.
      shown = lv |> element("#mfa-recovery-codes") |> render()
      [_, a_code | _] = Regex.run(~r/([a-z2-7]{16})/, shown)
      assert is_binary(a_code)

      render_click(lv, "toggle_codes_saved", %{})
      dismissed = render_click(lv, "dismiss_recovery_codes", %{})
      refute has_element?(lv, "#mfa-recovery-codes")
      refute dismissed =~ a_code

      {:ok, _lv2, remounted} = live(conn, ~p"/app/#{account}/settings/profile")
      refute remounted =~ "mfa-recovery-codes"
      refute remounted =~ a_code
    end

    test "cancel_mfa drops the pending secret so confirm refuses", %{conn: conn, account: account} do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      begin_mfa_enrollment(lv)
      render_click(lv, "cancel_mfa", %{})

      # Cancel removes the form from the DOM; a stale client could still
      # push the event, so fire it directly.
      html = render_submit(lv, "confirm_mfa", %{"mfa" => %{"otp" => "123456"}})

      assert html =~ "Start MFA setup again."
    end

    test "disabling MFA without a code is rejected and MFA stays enabled", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      secret = Auth.generate_mfa_secret()

      {_user, _codes} =
        Fixtures.Memberships.enable_mfa!(secret, Fixtures.Subjects.subject_for(owner))

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      html = render_click(lv, "disable_mfa", %{})

      assert html =~ "Authenticator or recovery code"
      assert html =~ "That code did not match. Try again."
      reloaded = Emisar.Repo.reload!(owner)
      assert %DateTime{} = reloaded.mfa_enabled_at
    end

    test "regenerate + disable for an MFA-enabled user", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      secret = Auth.generate_mfa_secret()

      {_user, _codes} =
        Fixtures.Memberships.enable_mfa!(secret, Fixtures.Subjects.subject_for(owner))

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      render_click(lv, "start_regenerate_recovery_codes", %{})

      assert submit_recovery_code_regeneration(lv, secret) =~ "New recovery codes generated."

      shown = lv |> element("#mfa-recovery-codes") |> render()
      [_, recovery_code | _] = Regex.run(~r/([a-z2-7]{16})/, shown)

      render_click(lv, "start_disable_mfa", %{})

      html =
        render_submit(lv, "disable_mfa", %{"mfa_disable" => %{"code" => recovery_code}})

      # The disable drops this socket too, so it reconnects and the "MFA
      # disabled." flash may not survive the remount. What the operator is
      # actually owed is the durable outcome: the factor is gone and the card
      # offers setup again.
      assert html =~ "Set up MFA"
      refute html =~ "Disable MFA"
      refute Emisar.Repo.reload!(owner).mfa_enabled_at
    end

    test "recovery-code regeneration refuses missing or wrong proof without replacement", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      secret = Auth.generate_mfa_secret()

      {enrolled, _codes} =
        Fixtures.Memberships.enable_mfa!(secret, Fixtures.Subjects.subject_for(owner))

      old_digests = enrolled.mfa_recovery_codes
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      html = render_click(lv, "regenerate_recovery_codes", %{})
      assert html =~ "That code did not match. Try again."
      refute has_element?(lv, "#mfa-recovery-codes")
      assert Emisar.Repo.reload!(owner).mfa_recovery_codes == old_digests

      render_click(lv, "start_regenerate_recovery_codes", %{})

      html =
        render_submit(lv, "regenerate_recovery_codes", %{
          "mfa_recovery_regeneration" => %{"code" => "not-a-code"}
        })

      assert html =~ "That code did not match. Try again."
      refute has_element?(lv, "#mfa-recovery-codes")
      assert Emisar.Repo.reload!(owner).mfa_recovery_codes == old_digests
    end

    test "recovery regeneration start, cancel, and disable forms stay mutually exclusive", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      secret = Auth.generate_mfa_secret()

      Fixtures.Memberships.enable_mfa!(secret, Fixtures.Subjects.subject_for(owner))
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      render_click(lv, "start_regenerate_recovery_codes", %{})
      assert has_element?(lv, "#mfa_recovery_regeneration_form")
      refute has_element?(lv, "#mfa_disable_form")

      render_click(lv, "start_disable_mfa", %{})
      refute has_element?(lv, "#mfa_recovery_regeneration_form")
      assert has_element?(lv, "#mfa_disable_form")

      assert has_element?(lv, "#mfa_disable_form button", "Disable MFA")
      refute has_element?(lv, "#mfa_disable_form button", "Confirm and disable")

      disable_submit =
        lv |> element("#mfa_disable_form button", "Disable MFA") |> render()

      assert disable_submit =~ "border-rose-500/40"
      refute disable_submit =~ "bg-brand-500"

      render_click(lv, "start_regenerate_recovery_codes", %{})
      assert has_element?(lv, "#mfa_recovery_regeneration_form")
      refute has_element?(lv, "#mfa_disable_form")

      render_click(lv, "cancel_regenerate_recovery_codes", %{})
      refute has_element?(lv, "#mfa_recovery_regeneration_form")
    end

    test "a replayed authenticator code stays inline and preserves the old set", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      secret = Auth.generate_mfa_secret()

      {enrolled, _codes} =
        Fixtures.Memberships.enable_mfa!(secret, Fixtures.Subjects.subject_for(owner))

      old_digests = enrolled.mfa_recovery_codes
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      render_click(lv, "start_regenerate_recovery_codes", %{})

      {consumed_bucket, response_bucket} = submit_replayed_mfa_code(lv, enrolled, secret)

      # An expired code is invalid, not replayed. Retry only that exact branch
      # after a measured rollover; a same-bucket error must fail this test.
      {consumed_bucket, response_bucket} =
        if response_bucket > consumed_bucket and
             has_element?(
               lv,
               "#mfa_recovery_regeneration_form",
               "That code did not match. Try again."
             ) do
          refute has_element?(lv, "#mfa-recovery-codes")
          assert Emisar.Repo.reload!(owner).mfa_recovery_codes == old_digests
          submit_replayed_mfa_code(lv, enrolled, secret)
        else
          {consumed_bucket, response_bucket}
        end

      assert has_element?(
               lv,
               "#mfa_recovery_regeneration_form",
               "already used. Wait for the next authenticator code."
             ),
             "Expected inline replay: consumed bucket #{consumed_bucket}, response bucket #{response_bucket}"

      refute has_element?(lv, "#mfa-recovery-codes")
      assert Emisar.Repo.reload!(owner).mfa_recovery_codes == old_digests
    end

    test "a concurrent MFA disable closes stale regeneration controls", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      secret = Auth.generate_mfa_secret()

      {owner, _codes} =
        Fixtures.Memberships.enable_mfa!(secret, Fixtures.Subjects.subject_for(owner))

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      render_click(lv, "start_regenerate_recovery_codes", %{})

      Fixtures.Memberships.set_mfa_state(owner,
        mfa_secret: nil,
        mfa_enabled_at: nil,
        mfa_recovery_codes: []
      )

      render_submit(lv, "regenerate_recovery_codes", %{
        "mfa_recovery_regeneration" => %{
          "code" => Fixtures.Auth.totp_code(secret)
        }
      })

      assert_redirect(lv, ~p"/app/#{account}/settings/profile")
    end

    test "an exhausted shared MFA window leaves regeneration open and codes unchanged", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      secret = Auth.generate_mfa_secret()

      {enrolled, _codes} =
        Fixtures.Memberships.enable_mfa!(secret, Fixtures.Subjects.subject_for(owner))

      old_digests = enrolled.mfa_recovery_codes
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")
      render_click(lv, "start_regenerate_recovery_codes", %{})

      for _ <- 1..5 do
        assert Auth.verify_mfa_challenge(enrolled.id, {:totp, "000000"}) == {:error, :invalid}
      end

      html =
        render_submit(lv, "regenerate_recovery_codes", %{
          "mfa_recovery_regeneration" => %{
            "code" => Fixtures.Auth.totp_code(secret)
          }
        })

      assert html =~ "Too many attempts. Wait a few minutes, then try again."
      assert has_element?(lv, "#mfa_recovery_regeneration_form")
      refute has_element?(lv, "#mfa-recovery-codes")
      assert Emisar.Repo.reload!(owner).mfa_recovery_codes == old_digests
    end

    test "a wrong code stays inline and leaves MFA enabled", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      secret = Auth.generate_mfa_secret()

      {_user, _codes} =
        Fixtures.Memberships.enable_mfa!(secret, Fixtures.Subjects.subject_for(owner))

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      render_click(lv, "start_disable_mfa", %{})

      html =
        render_submit(lv, "disable_mfa", %{
          "mfa_disable" => %{"code" => "not-a-real-code"}
        })

      assert html =~ "That code did not match. Try again."
      refute html =~ "Could not disable MFA."
      assert %DateTime{} = Emisar.Repo.reload!(owner).mfa_enabled_at
    end

    test "an exhausted MFA window refuses the disable inline and leaves MFA on", %{
      conn: conn,
      owner: owner,
      account: account
    } do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      secret = Auth.generate_mfa_secret()

      {enrolled, _codes} =
        Fixtures.Memberships.enable_mfa!(secret, Fixtures.Subjects.subject_for(owner))

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/profile")

      render_click(lv, "start_disable_mfa", %{})

      # Spend the shared per-user window elsewhere; this step-up inherits it.
      for _ <- 1..5 do
        assert Auth.verify_mfa_challenge(enrolled.id, {:totp, "000000"}) == {:error, :invalid}
      end

      otp = Fixtures.Auth.totp_code(secret)
      html = render_submit(lv, "disable_mfa", %{"mfa_disable" => %{"code" => otp}})

      # The refusal renders at the code input and the step stays open to retry.
      assert html =~ "Too many attempts. Wait a few minutes, then try again."
      assert html =~ "Authenticator or recovery code"
      assert %DateTime{} = Emisar.Repo.reload!(owner).mfa_enabled_at
    end
  end

  defp browser_subject(conn, member, account),
    do: Fixtures.Subjects.subject_for(member, session: session_token(conn, account))

  # Count of session rows rendered on the current page — each stream row is an
  # <li id="sessions-<uuid>">, so the ids that match are exactly this page's rows.
  defp rendered_session_rows(lv) do
    lv
    |> render()
    |> then(&Regex.scan(~r/id="sessions-[0-9a-f-]+"/, &1))
    |> length()
  end

  defp mfa_secret_from(html) do
    # The setup panel renders the Base32 secret for manual entry.
    [_, encoded] = Regex.run(~r/data-copy-text="([A-Z2-7]+)"/, html)
    Base.decode32!(encoded, padding: false)
  end

  defp begin_mfa_enrollment(lv) do
    render_click(lv, "start_mfa", %{})
    assert_received {:email, email}
    code = Fixtures.Auth.code_from_email(email)

    render_hook(lv, "verify_mfa_enrollment_email", %{
      "mfa_enrollment" => %{"code" => code}
    })
  end

  defp submit_replayed_mfa_code(lv, member, secret) do
    sampled_at = DateTime.utc_now()
    otp = NimbleTOTP.verification_code(secret, time: sampled_at)

    assert {:ok, _member} =
             Emisar.Accounts.verify_and_consume_member_mfa(member, otp,
               clock: fn -> sampled_at end
             )

    render_submit(lv, "regenerate_recovery_codes", %{
      "mfa_recovery_regeneration" => %{"code" => otp}
    })

    {totp_bucket(sampled_at), totp_bucket(DateTime.utc_now())}
  end

  # Submits a valid authenticator code to the regeneration form. `Crypto.valid_totp?/3`
  # allows NO window, so a code minted at the end of a 30-second bucket is refused as
  # invalid once the server's clock lands in the next one — the measured cause of the
  # "regenerate + disable" flake. A refusal leaves `mfa_last_used_at` unset, so
  # retrying with the now-current code cannot be rejected as a replay. Retry ONLY that
  # measured straddle: a same-bucket refusal is a genuine failure and is returned as-is
  # for the caller's assertion.
  defp submit_recovery_code_regeneration(lv, secret) do
    sampled_at = DateTime.utc_now()

    html =
      render_submit(lv, "regenerate_recovery_codes", %{
        "mfa_recovery_regeneration" => %{
          "code" => NimbleTOTP.verification_code(secret, time: sampled_at)
        }
      })

    if html =~ "New recovery codes generated." or
         totp_bucket(DateTime.utc_now()) == totp_bucket(sampled_at) do
      html
    else
      render_submit(lv, "regenerate_recovery_codes", %{
        "mfa_recovery_regeneration" => %{"code" => Fixtures.Auth.totp_code(secret)}
      })
    end
  end

  defp totp_bucket(%DateTime{} = at), do: div(DateTime.to_unix(at), 30)

  # Submits the enrollment form, retrying once across a 30s-window straddle (the
  # code-gen/validate boundary) — the same flake Fixtures.Memberships.enroll_mfa guards, but
  # through the LiveView form. A straddle re-renders the form without the success
  # flash, so a second submit with a fresh code lands in a stable window.
  defp submit_mfa_enrollment(lv, secret) do
    html =
      render_hook(lv, "confirm_mfa", %{"mfa" => %{"otp" => Fixtures.Auth.totp_code(secret)}})

    if html =~ "MFA enabled." do
      html
    else
      render_hook(lv, "confirm_mfa", %{"mfa" => %{"otp" => Fixtures.Auth.totp_code(secret)}})
    end
  end

  # Concurrent-completion tests expect a redirect rather than the success
  # flash above, but have the same real-clock TOTP boundary. Retry only the
  # rendered invalid-code branch once with the next current code.
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
