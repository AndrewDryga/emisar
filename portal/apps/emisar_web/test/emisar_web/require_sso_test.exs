defmodule EmisarWeb.RequireSSOTest do
  @moduledoc """
  A workspace's `require_sso` (plan §3 "Sign-in", §3.1 "Workspace policy
  change"): while it is on, only an SSO session of this workspace reaches it.
  An email-code session is dropped and sent to the workspace's sign-in, the
  email code is refused on the server (behind the same decoy page), and turning
  the requirement on ends the workspace's email-code sessions at once, open
  LiveViews included. SSO sessions and other workspaces are untouched. The
  owner-only toggle can't be turned on without an enabled SSO connection.
  (An invitee's continue-with-SSO step is in `EmisarWeb.SSOControllerTest`.)
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Auth, Repo}
  alias Emisar.Auth.UserToken

  defp enabled_provider(account) do
    Fixtures.Accounts.create_subscription(account, "team")
    Fixtures.SSO.create_identity_provider(account_id: account.id, name: "Acme Okta")
  end

  defp require_sso!(account),
    do: Fixtures.Accounts.set_account_settings(account, %{require_sso: true})

  defp sso_conn(member, provider) do
    identity = Fixtures.SSO.create_user_identity(provider_id: provider.id, membership: member)
    log_in_member(build_conn(), member, auth_method: :sso, user_identity_id: identity.id)
  end

  describe "enforcement" do
    setup %{conn: conn} do
      {conn, owner, account} = register_and_log_in(conn)
      %{conn: conn, owner: owner, account: account}
    end

    test "require_sso OFF — an email-code session reaches the workspace", %{
      conn: conn,
      account: account
    } do
      assert {:ok, _lv, _html} = live(conn, ~p"/app/#{account}/runners")
    end

    test "require_sso ON — an email-code session is dropped and sent to the workspace sign-in",
         %{conn: conn, account: account} do
      _ = enabled_provider(account)
      require_sso!(account)
      token = session_token(conn, account)

      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/app/#{account}/runners")
      assert to == ~p"/app/#{account}/sign_in"
      assert Auth.fetch_session_by_token(token, account.id) == {:error, :not_found}
    end

    test "require_sso ON — an SSO session of this workspace reaches it", %{
      owner: owner,
      account: account
    } do
      provider = enabled_provider(account)
      require_sso!(account)

      assert {:ok, _lv, _html} = live(sso_conn(owner, provider), ~p"/app/#{account}/runners")
    end

    test "require_sso ON — another workspace's SSO session never reaches this one", %{
      owner: owner,
      account: account
    } do
      # This workspace HAS a usable connection (so the gate is live)…
      _ = enabled_provider(account)
      require_sso!(account)

      # …but the SSO session belongs to the same person's Member elsewhere.
      {_c2, _o2, other} = register_and_log_in(build_conn())

      other_member =
        Fixtures.Memberships.create_membership(account_id: other.id, email: owner.email)

      foreign = sso_conn(other_member, enabled_provider(other))

      assert {:error, {:redirect, %{to: to}}} = live(foreign, ~p"/app/#{account}/runners")
      assert to == ~p"/app/#{account}/sign_in"
    end

    test "require_sso ON with NO enabled connection fails OPEN, not a brick", %{
      conn: conn,
      account: account
    } do
      Fixtures.Accounts.create_subscription(account, "team")
      require_sso!(account)

      # No enabled provider exists, so the gate could never be satisfied: it fails
      # open rather than locking everyone out (the provider write paths keep the
      # UI from getting here; this covers an out-of-band removal).
      assert {:ok, _lv, _html} = live(conn, ~p"/app/#{account}/runners")
    end

    test "require_sso ON — the email code is refused on the server, behind the same page", %{
      owner: owner,
      account: account
    } do
      _ = enabled_provider(account)
      require_sso!(account)

      refused =
        post(build_conn(), ~p"/app/#{account}/sign_in/email", %{
          "user" => %{"email" => owner.email}
        })

      assert redirected_to(refused) == ~p"/sign_in/magic?sent=1"
      assert refused.resp_cookies["emisar_magic"]

      assert UserToken.Query.by_id(get_session(refused, :magic_link_token_id)) |> Repo.one() ==
               nil

      refute_received {:email, _code}
    end
  end

  describe "turning require_sso on" do
    test "ends the workspace's email-code sessions and their LiveViews; SSO sessions and other workspaces survive",
         %{conn: conn} do
      {owner_conn, owner, account} = register_and_log_in(conn, %{account: %{plan: "team"}})
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      admin_conn = sso_conn(owner, provider)

      # A teammate signed in by email, whose browser also holds a session in the
      # same person's other workspace.
      teammate = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")
      {_other_conn, _other_owner, other} = register_and_log_in(build_conn())

      teammate_elsewhere =
        Fixtures.Memberships.create_membership(account_id: other.id, email: teammate.email)

      browser = build_conn() |> log_in_member(teammate) |> log_in_member(teammate_elsewhere)

      sso_member = Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")
      sso_browser = sso_conn(sso_member, provider)

      {:ok, email_lv, _html} = live(browser, ~p"/app/#{account}/runners")
      {:ok, elsewhere_lv, _html} = live(browser, ~p"/app/#{other}/runners")
      {:ok, sso_lv, _html} = live(sso_browser, ~p"/app/#{account}/runners")

      {:ok, team, _html} = live(admin_conn, ~p"/app/#{account}/settings/team")
      render_click(team, "toggle_require_sso", %{})
      assert Repo.reload!(account).settings.require_sso

      {to, _flash} = assert_redirect(email_lv, 1_000)
      assert URI.parse(to).path == ~p"/app/#{account}/runners"

      for {owner_or_teammate, conn} <- [{owner, owner_conn}, {teammate, browser}] do
        assert Auth.fetch_session_by_token(session_token(conn, account), account.id) ==
                 {:error, :not_found},
               "#{owner_or_teammate.email}'s email session survived"
      end

      assert render(elsewhere_lv) =~ "Runners"
      assert render(sso_lv) =~ "Runners"
      assert render(team) =~ account.name
      assert {:ok, _live} = Auth.fetch_session_by_token(session_token(browser, other), other.id)

      assert {:ok, _live} =
               Auth.fetch_session_by_token(session_token(sso_browser, account), account.id)
    end
  end

  describe "the owner toggle" do
    setup %{conn: conn} do
      {conn, owner, account} = register_and_log_in(conn)
      %{conn: conn, owner: owner, account: account}
    end

    test "owner turns it on when an enabled SSO connection exists", %{
      owner: owner,
      account: account
    } do
      provider = enabled_provider(account)

      {:ok, lv, _html} = live(sso_conn(owner, provider), ~p"/app/#{account}/settings/team")
      render_click(lv, "toggle_require_sso", %{})

      assert Repo.reload!(account).settings.require_sso
    end

    test "owner cannot turn it on with no connection — flashed, no change (handler guards too)",
         %{conn: conn, account: account} do
      Fixtures.Accounts.create_subscription(account, "team")
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/team")
      html = render_click(lv, "toggle_require_sso", %{})

      assert html =~ "Add an enabled SSO connection"
      refute Repo.reload!(account).settings.require_sso
    end

    test "a viewer cannot toggle it", %{account: account} do
      _ = enabled_provider(account)
      viewer = Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")

      {:ok, lv, _html} =
        build_conn() |> log_in_member(viewer) |> live(~p"/app/#{account}/settings/team")

      html = render_click(lv, "toggle_require_sso", %{})

      assert html =~ "Only owners and admins"
      refute Repo.reload!(account).settings.require_sso
    end
  end
end
