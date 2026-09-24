defmodule EmisarWeb.MemberOnlySessionTest do
  @moduledoc """
  A member-only SSO session: a workspace Member without a personal login acts
  in its one workspace, sees a plain no-personal-login state where personal
  controls would be, and loses the workspace on HTTP and on LiveView reconnect
  once its Member, identity or provider is revoked.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Accounts, Auth, Fixtures}

  setup %{conn: conn} do
    {_owner, account, owner_subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})
    provider = Fixtures.SSO.create_identity_provider(account_id: account.id)

    membership =
      Fixtures.Memberships.create_unlinked_membership(account_id: account.id, role: "admin")

    identity =
      Fixtures.SSO.create_user_identity(
        account_id: account.id,
        provider_id: provider.id,
        membership: membership
      )

    token = Fixtures.Auth.create_member_session_token!(membership, identity)
    conn = conn |> init_test_session(%{}) |> put_session(:user_token, token)

    %{
      conn: conn,
      account: account,
      owner_subject: owner_subject,
      provider: provider,
      membership: membership,
      identity: identity,
      token: token
    }
  end

  test "opens its one workspace as the Member and cannot switch away", %{
    conn: conn,
    account: account,
    membership: membership
  } do
    other = Fixtures.Accounts.create_account(plan: "team")

    assert redirected_to(get(conn, ~p"/app")) == ~p"/app/#{account}"
    assert {:ok, _lv, html} = live(conn, ~p"/app/#{account}")
    assert html =~ membership.display_name
    refute html =~ "Verify your email"

    switched = post(conn, ~p"/app/accounts/switch", %{"account_id" => other.id})
    assert redirected_to(switched) == ~p"/app"

    assert Phoenix.Flash.get(switched.assigns.flash, :error) ==
             "You aren't a member of that account."

    assert_error_sent 404, fn -> get(conn, ~p"/app/#{other}") end
  end

  test "Profile edits the workspace name and shows no personal controls", %{
    conn: conn,
    account: account
  } do
    {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/profile")

    assert html =~ "has no personal login"
    assert html =~ ~s(id="member-link-form")
    refute html =~ "Personal details"
    refute html =~ "Active sessions"
    assert render_click(lv, "edit_profile") =~ "has no personal login."

    render_click(lv, "edit_workspace_profile")

    html =
      lv
      |> form("#workspace-profile-form", workspace_profile: %{display_name: "Renamed Member"})
      |> render_submit()

    assert html =~ "Workspace name updated."
    assert html =~ "Renamed Member"
  end

  test "MFA setup offers a personal login before any factor", %{conn: conn, account: account} do
    Fixtures.Accounts.set_account_settings(account, %{require_mfa: true})

    assert {:error, {:redirect, %{to: "/app/mfa_setup"}}} = live(conn, ~p"/app/#{account}")
    assert {:ok, _lv, html} = live(conn, ~p"/app/mfa_setup")
    assert html =~ "has no personal login yet"
    assert html =~ ~s(id="member-link-form")
    refute html =~ "Email me a verification code"
  end

  test "Team MFA reset offers only its IdP, or asks for a personal login", %{
    conn: conn,
    account: account,
    provider: provider
  } do
    target_user =
      Fixtures.Users.create_user()
      |> Fixtures.Users.set_mfa_state(
        mfa_secret: "JBSWY3DPEHPK3PXP",
        mfa_enabled_at: DateTime.utc_now(),
        mfa_recovery_codes: []
      )

    target =
      Fixtures.Memberships.create_membership(account_id: account.id, user_id: target_user.id)

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/team/#{target.id}/reset_mfa")

    assert html =~ "A personal login is required"
    refute html =~ "Your authenticator code"

    provider |> Ecto.Changeset.change(satisfies_mfa: true) |> Emisar.Repo.update!()
    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/team/#{target.id}/reset_mfa")

    assert html =~ "Verify with #{provider.name} and reset MFA"
    refute html =~ "A personal login is required"
    refute html =~ "Your authenticator code"
  end

  test "workspace creation sends a member-only session to recovery, which offers its workspace",
       %{conn: conn, account: account} do
    account_count = Emisar.Repo.aggregate(Accounts.Account, :count)

    created = post(conn, ~p"/onboarding", %{"account" => %{"name" => "Second workspace"}})
    assert redirected_to(created) == ~p"/session/recover?reason=personal_required"
    assert Emisar.Repo.aggregate(Accounts.Account, :count) == account_count

    html = conn |> get(~p"/session/recover?reason=personal_required") |> html_response(200)
    assert html =~ "Continue to #{account.name}"
    assert html =~ "Creating a workspace needs a personal login"
    assert html =~ ~s(href="/app/#{account.slug}/settings/profile")
    refute html =~ "sign in by email"
  end

  test "personal SSO flows refuse a member-only session", %{
    conn: conn,
    account: account,
    provider: provider,
    membership: membership
  } do
    linked =
      conn
      |> post(~p"/app/#{account}/settings/sso/identity/link", %{"handoff" => "forged"})

    assert redirected_to(linked) == ~p"/app/#{account}/settings/profile"

    reset = post(conn, ~p"/app/#{account}/settings/team/#{membership.id}/reset_mfa/sso")
    assert redirected_to(reset) == ~p"/app/#{account}/settings/team"

    stepped_up = post(conn, ~p"/app/#{account}/sso_required", %{"provider_id" => provider.id})
    assert redirected_to(stepped_up) == ~p"/app/#{account}/sso_required"

    callback =
      conn
      |> put_session(:sso_session_step_up, %{account_id: account.id})
      |> get(~p"/sign_in/sso/callback")

    assert redirected_to(callback) == ~p"/session/recover?reason=sso_incomplete"
  end

  for revocation <- [:suspended, :identity_retired, :provider_disabled] do
    test "a #{revocation} Member loses the workspace on HTTP and on LiveView reconnect", %{
      conn: conn,
      account: account,
      owner_subject: owner_subject,
      provider: provider,
      membership: membership,
      identity: identity,
      token: token
    } do
      rendered = get(conn, ~p"/app/#{account}")
      assert html_response(rendered, 200)

      case unquote(revocation) do
        :suspended ->
          topic = Auth.live_socket_topic_for_session(token)
          EmisarWeb.Endpoint.subscribe(topic)
          assert {:ok, _suspended} = Accounts.suspend_membership(membership, owner_subject)
          assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 500

        :identity_retired ->
          Fixtures.SSO.retire_identity(identity)

        :provider_disabled ->
          Fixtures.SSO.disable_provider(provider)
      end

      assert {%{reason: "reload", status: 404}, _call} = catch_exit(live(rendered))
      assert_error_sent 404, fn -> get(conn, ~p"/app/#{account}") end

      signed_out = get(conn, ~p"/app")
      assert redirected_to(signed_out) == ~p"/sign_in"
      assert Auth.fetch_session_by_token(token) == {:error, :not_found}
    end
  end
end
