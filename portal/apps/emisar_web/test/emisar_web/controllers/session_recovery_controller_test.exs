defmodule EmisarWeb.SessionRecoveryControllerTest do
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Accounts, Auth}
  alias EmisarWeb.UserAuth

  setup %{conn: conn} do
    account = Fixtures.Accounts.create_account()
    user = Fixtures.Users.create_user()

    member =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: :viewer
      )

    owner = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account)
    conn = log_in_user(conn, user)
    %{conn: conn, user: user, account: account, member: member, owner: owner}
  end

  test "a grantless bearer reaches recovery through /app, not false onboarding or a loop", %{
    conn: conn,
    account: account,
    member: member,
    owner: owner
  } do
    raw = get_session(conn, :user_token)
    assert Accounts.end_all_sessions_for(member, owner) == :ok
    conn = get(conn, ~p"/app")
    assert redirected_to(conn) == ~p"/session/recover"
    conn = get(conn, ~p"/session/recover")
    html = html_response(conn, 200)
    assert html =~ "Choose how to continue"
    assert html =~ "Sign out and sign in again"
    refute html =~ account.name
    refute html =~ "Create your workspace"
    assert get_session(conn, :user_token) == raw
    assert {:ok, _session} = Auth.fetch_session_by_token(raw)
  end

  test "the recovery choice shows surviving proof, never late or revoked workspaces", %{
    conn: conn,
    user: user,
    account: account,
    member: member,
    owner: owner
  } do
    sibling = Fixtures.Accounts.create_account(name: "Surviving workspace")
    Fixtures.Memberships.create_membership(account_id: sibling.id, user_id: user.id)
    conn = log_in_user(conn, user)
    late = Fixtures.Accounts.create_account(name: "Not proved yet")
    Fixtures.Memberships.create_membership(account_id: late.id, user_id: user.id)
    assert Accounts.end_all_sessions_for(member, owner) == :ok
    html = conn |> get(~p"/session/recover") |> html_response(200)
    assert html =~ "Continue to #{sibling.name}"
    refute html =~ account.name
    refute html =~ late.name
  end

  @tag :grant_review
  test "recovery exposes a usable sibling when the pinned workspace needs unavailable SSO", %{
    conn: conn,
    user: user,
    account: account
  } do
    Fixtures.Accounts.maybe_seed_plan(account, "team")
    Fixtures.SSO.create_identity_provider(account_id: account.id)
    Fixtures.Accounts.set_account_settings(account, %{require_sso: true})
    sibling = Fixtures.Accounts.create_account(name: "Usable sibling")
    Fixtures.Memberships.create_membership(account_id: sibling.id, user_id: user.id)
    conn = conn |> log_in_user(user) |> put_session(:current_account_id, account.id)
    raw = get_session(conn, :user_token)
    late = Fixtures.Accounts.create_account(name: "Later unproved workspace")
    Fixtures.Memberships.create_membership(account_id: late.id, user_id: user.id)

    assert redirected_to(get(conn, ~p"/app/#{account}")) == ~p"/app/#{account}/sso_required"
    shown = get(conn, ~p"/session/recover")
    html = html_response(shown, 200)
    assert html =~ "Continue to #{sibling.name}"
    refute html =~ late.name
    assert get_session(shown, :user_token) == raw
    assert html_response(get(conn, ~p"/app/#{sibling}"), 200)
  end

  test "recovery keeps the workspace switcher's choices beyond the default first page", %{
    conn: conn,
    user: user
  } do
    accounts =
      for index <- 1..21 do
        account = Fixtures.Accounts.create_account(name: "Workspace #{index}")
        Fixtures.Memberships.create_membership(account_id: account.id, user_id: user.id)
        account
      end

    shown = conn |> log_in_user(user) |> get(~p"/session/recover")
    html = html_response(shown, 200)

    for account <- accounts do
      assert html =~ ~s(href="/app/#{account.slug}")
    end
  end

  test "explicit CSRF-protected restart signs out only this browser and preserves a proved branded target",
       %{
         conn: conn,
         user: user,
         account: account
       } do
    raw = get_session(conn, :user_token)
    other = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
    shown = get(conn, ~p"/session/recover")

    [csrf] =
      shown.resp_body
      |> LazyHTML.from_document()
      |> LazyHTML.query("form input[name='_csrf_token']")
      |> LazyHTML.attribute("value")

    protected = shown |> recycle() |> put_private(:plug_skip_csrf_protection, false)

    assert_error_sent(403, fn -> post(protected, ~p"/session/recover", %{}) end)
    assert {:ok, _session} = Auth.fetch_session_by_token(raw)

    restarted =
      post(protected, ~p"/session/recover", %{
        "_csrf_token" => csrf,
        "account_id_or_slug" => account.id
      })

    assert redirected_to(restarted) == ~p"/app/#{account}/sign_in"
    refute get_session(restarted, :user_token)
    assert Auth.fetch_session_by_token(raw) == {:error, :not_found}
    assert {:ok, _session} = Auth.fetch_session_by_token(other)
    assert html_response(get(restarted, ~p"/app/#{account}/sign_in"), 200) =~ "Sign in to"
  end

  test "an unproved or external restart target cannot redirect or disclose a workspace", %{
    conn: conn
  } do
    foreign = Fixtures.Accounts.create_account(name: "Private workspace")

    for target <- [foreign.id, "https://attacker.test/", "//attacker.test/"] do
      restarted = post(conn, ~p"/session/recover", %{"account_id_or_slug" => target})
      assert redirected_to(restarted) == ~p"/sign_in"
      refute restarted.resp_body =~ foreign.name
      assert html_response(get(restarted, ~p"/sign_in"), 200) =~ "Sign in"
    end
  end

  test "an anonymous or expired browser can render recovery without a redirect", %{conn: conn} do
    Auth.delete_session_token(get_session(conn, :user_token))
    html = conn |> get(~p"/session/recover") |> html_response(200)
    assert html =~ "Your session has ended"
    assert html =~ ~s|href="/sign_in"|
    refute html =~ "Continue to"
  end

  test "first-time personal sign-in still reaches real onboarding", %{conn: conn} do
    new_user = Fixtures.Users.create_user()
    conn = conn |> log_in_user(new_user) |> get(~p"/app")
    assert redirected_to(conn) == ~p"/onboarding"
    assert html_response(get(conn, ~p"/onboarding"), 200) =~ "Create your workspace"
  end

  @tag :step_up_review
  test "an unaccepted invitation does not trap a first-time personal sign-in in recovery", %{
    conn: conn,
    owner: owner
  } do
    new_user = Fixtures.Users.create_user()

    assert {:ok, %{membership: membership}} =
             Accounts.invite_user_to_account(%{email: new_user.email, role: "viewer"}, owner)

    assert membership.invitation_token_digest
    assert is_nil(membership.invitation_accepted_at)
    conn = conn |> log_in_user(new_user) |> get(~p"/app")
    assert redirected_to(conn) == ~p"/onboarding"
    assert html_response(get(conn, ~p"/onboarding"), 200) =~ "Create your workspace"
  end

  test "a held LiveView with a live bearer but lost grant uses the renderable recovery route", %{
    conn: conn,
    user: user,
    account: account,
    member: member,
    owner: owner
  } do
    {:ok, session} =
      Auth.fetch_session_by_token(get_session(conn, :user_token))

    subject = Fixtures.Subjects.subject_for(user, account, session: session)
    assert Accounts.end_all_sessions_for(member, owner) == :ok

    socket = %Phoenix.LiveView.Socket{
      assigns: %{current_subject: subject, current_account: account, flash: %{}, __changed__: %{}}
    }

    assert %{redirected: {:redirect, %{to: "/session/recover"}}} = UserAuth.reauthenticate(socket)
    assert html_response(get(conn, ~p"/session/recover"), 200) =~ "Choose how to continue"
  end
end
