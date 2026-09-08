defmodule EmisarWeb.MemberRoleLiveTest do
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Accounts, Repo}
  alias Emisar.Accounts.RunnerAccess

  test "Owner promotion describes the wider access without a reconnection warning", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    target = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
    Fixtures.Memberships.force_runner_access(target, RunnerAccess.none())
    {:ok, view, _html} = live(conn, ~p"/app/#{account}/settings/team")

    assert has_element?(view, "#change-role-#{target.id}-owner", "access all runners and packs")
    refute has_element?(view, "#change-role-#{target.id}-owner", "credentials")
    refute has_element?(view, "#change-role-#{target.id}-owner", "reconnect")
  end

  test "Owner rows have no access editor and role changes lead to an explicit grant", %{
    conn: conn
  } do
    {conn, _user, account} = register_and_log_in(conn)
    target = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")
    {:ok, view, _html} = live(conn, ~p"/app/#{account}/settings/team")

    refute has_element?(
             view,
             "[phx-click='start_scope_edit'][phx-value-membership_id='#{target.id}']"
           )

    assert has_element?(
             view,
             "a[href='/app/#{account.slug}/settings/team/#{target.id}/change-role/admin']"
           )

    refute has_element?(view, "#change-role-#{target.id}-admin")
  end

  test "Owner invitations display fixed account-wide access", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    {:ok, view, _html} = live(conn, ~p"/app/#{account}/settings/team/invite")

    html = view |> form("#invite_form", invite: %{role: "owner"}) |> render_change()
    assert html =~ "All runners"
    assert html =~ "All packs"
    refute has_element?(view, "input[name='invite[runner_access_mode]']")
    refute has_element?(view, "input[name='invite[pack_access_mode]']")
  end

  test "a demotion starts with no choice and saves only the explicitly selected access", %{
    conn: conn
  } do
    {conn, _user, account} = register_and_log_in(conn)
    target = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")

    {:ok, view, _html} =
      live(conn, ~p"/app/#{account}/settings/team/#{target.id}/change-role/admin")

    refute has_element?(view, "input[type='radio'][checked]")
    html = view |> form("#owner-role-form") |> render_submit()
    assert html =~ "Choose their runner access"
    assert Repo.reload!(target).role == :owner
    assert Accounts.subscribe_account_team(account.id) == :ok

    view |> form("#owner-role-form", access: %{runner_access_mode: "none"}) |> render_submit()
    assert_redirect(view, ~p"/app/#{account}/settings/team")
    assert Repo.reload!(target).role == :admin
    assert Accounts.runner_access_for_membership(account.id, target.id) == RunnerAccess.none()
    user_id = target.user_id
    assert_receive {:list_changed, :team, "membership.role_changed", ^user_id}
  end

  test "malformed selection values do not crash the editor or change the Owner", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    target = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")

    {:ok, view, _html} =
      live(conn, ~p"/app/#{account}/settings/team/#{target.id}/change-role/admin")

    assert render_change(view, "validate", %{"access" => %{"scope" => %{"unexpected" => "value"}}}) =~
             "That access selection isn"

    assert render_submit(view, "save", %{"access" => %{"runner_access_mode" => ["all"]}}) =~
             "That access selection isn"

    assert Repo.reload!(target).role == :owner
    assert has_element?(view, "#owner-role-form")
  end

  test "directory-owned Owners offer an explicit return to directory role and access", %{
    conn: conn
  } do
    {conn, _user, account} = register_and_log_in(conn)
    provider = Fixtures.SSO.create_identity_provider(account_id: account.id)

    target =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        role: "owner",
        runner_access_directory_managed: true,
        directory_provider_id: provider.id
      )

    {:ok, view, _html} =
      live(conn, ~p"/app/#{account}/settings/team/#{target.id}/change-role/directory")

    assert has_element?(view, "input[type='radio'][value='directory']")
    refute has_element?(view, "input[type='radio'][value='all']")
    assert render(view) =~ "Directory sync will set their role and access"
    assert Accounts.subscribe_account_team(account.id) == :ok

    view
    |> form("#owner-role-form", access: %{runner_access_mode: "directory"})
    |> render_submit()

    assert_redirect(view, ~p"/app/#{account}/settings/team")
    assert Repo.reload!(target).directory_authorization_pending_version == 0
    assert Accounts.runner_access_for_membership(account.id, target.id) == RunnerAccess.none()
    user_id = target.user_id
    assert_receive {:list_changed, :team, "membership.role_changed", ^user_id}
  end

  test "Admins cannot open an Owner demotion", %{conn: conn} do
    account = Fixtures.Accounts.create_account()
    admin = Fixtures.Users.create_user()

    Fixtures.Memberships.create_membership(
      account_id: account.id,
      user_id: admin.id,
      role: "admin"
    )

    target = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")
    conn = log_in_user(conn, admin)

    assert {:error, {:live_redirect, %{to: path}}} =
             live(conn, ~p"/app/#{account}/settings/team/#{target.id}/change-role/viewer")

    assert path == ~p"/app/#{account}/settings/team"
    assert Repo.reload!(target).role == :owner
  end

  test "an Owner cannot open another account's demotion form", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    foreign = Fixtures.Memberships.create_membership(role: "owner")

    assert {:error, {:live_redirect, %{to: path}}} =
             live(conn, ~p"/app/#{account}/settings/team/#{foreign.id}/change-role/viewer")

    assert path == ~p"/app/#{account}/settings/team"
    assert Repo.reload!(foreign).role == :owner
  end
end
