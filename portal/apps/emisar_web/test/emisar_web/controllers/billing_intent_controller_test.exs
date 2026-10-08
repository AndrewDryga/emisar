defmodule EmisarWeb.BillingIntentControllerTest do
  use EmisarWeb.ConnCase, async: true
  alias EmisarWeb.BillingIntent

  test "a signed-out Team choice is stored and lands on contextual signup", %{conn: conn} do
    token = BillingIntent.sign("team", :year)
    conn = get(conn, ~p"/start/team/#{token}")

    assert redirected_to(conn) == ~p"/sign_up?billing_intent=#{token}"
    assert get_session(conn, :billing_intent) == token
  end

  test "a forged choice clears pending state and falls back safely", %{conn: conn} do
    conn = Plug.Test.init_test_session(conn, %{billing_intent: "older"})
    conn = get(conn, ~p"/start/team/forged")

    assert redirected_to(conn) == ~p"/sign_up"
    refute get_session(conn, :billing_intent)
  end

  test "an authenticated Team choice opens a chooser without contacting Paddle", %{conn: conn} do
    {conn, _owner, account} = register_and_log_in(conn)
    token = BillingIntent.sign("team", :month)

    captured = get(conn, ~p"/start/team/#{token}")
    assert redirected_to(captured) == ~p"/app/billing/start"

    chooser = get(recycle(captured), ~p"/app/billing/start")
    html = html_response(chooser, 200)

    assert html =~ "Choose a workspace"
    assert html =~ "Selected plan"
    assert html =~ "Monthly"
    assert html =~ account.name
    label = html |> LazyHTML.from_document() |> LazyHTML.query("button span.font-mono")
    assert label |> LazyHTML.text() |> String.trim() == account.slug
    assert html =~ "review the price in checkout"
    assert html =~ "Cancel"
    refute html =~ "Keep my current plan"
    refute html =~ "Paddle.Initialize"
    refute account.paddle_customer_id
  end

  test "with several signed-in workspaces the operator picks the billed one", %{conn: conn} do
    {conn, owner, account_a} = register_and_log_in(conn)
    account_b = Fixtures.Accounts.create_account(%{name: "Billing Target"})

    owner_b =
      Fixtures.Memberships.create_membership(
        account_id: account_b.id,
        email: owner.email,
        role: "owner"
      )

    token = BillingIntent.sign("team", :year)
    captured = conn |> log_in_member(owner_b) |> get(~p"/start/team/#{token}")
    chooser = get(recycle(captured), ~p"/app/billing/start")
    html = html_response(chooser, 200)

    assert html =~ account_a.name
    assert html =~ "Billing Target"
    assert html =~ "Annual"

    selected =
      chooser
      |> recycle()
      |> post(~p"/app/billing/start", %{"account_id" => account_b.id})

    assert redirected_to(selected) ==
             ~p"/app/#{account_b}/settings/billing?billing_intent=#{token}"

    refute get_session(selected, :billing_intent)
    # Nothing switches: both workspaces stay signed in.
    assert length(get_session(selected, :sessions)) == 2
  end

  test "a signed-in workspace whose Member cannot manage billing is neither offered nor selectable",
       %{conn: conn} do
    {conn, owner, account_a} = register_and_log_in(conn)
    account_b = Fixtures.Accounts.create_account(%{name: "Viewer Space"})

    viewer_b =
      Fixtures.Memberships.create_membership(
        account_id: account_b.id,
        email: owner.email,
        role: "viewer"
      )

    token = BillingIntent.sign("team", :month)
    captured = conn |> log_in_member(viewer_b) |> get(~p"/start/team/#{token}")

    chooser = get(recycle(captured), ~p"/app/billing/start")
    html = html_response(chooser, 200)
    assert html =~ account_a.name
    refute html =~ "Viewer Space"

    denied =
      captured
      |> recycle()
      |> post(~p"/app/billing/start", %{"account_id" => account_b.id})

    html = html_response(denied, 200)
    assert html =~ "Only an owner, admin, or billing manager"
    assert get_session(denied, :billing_intent) == token
  end

  test "a workspace this browser is not signed in to is denied", %{conn: conn} do
    {conn, _owner, _account} = register_and_log_in(conn)
    {_foreign_owner, foreign, _subject} = Fixtures.Subjects.owner_subject()
    token = BillingIntent.sign("team", :month)
    captured = get(conn, ~p"/start/team/#{token}")

    denied =
      captured
      |> recycle()
      |> post(~p"/app/billing/start", %{"account_id" => foreign.id})

    assert html_response(denied, 200) =~ "Only an owner, admin, or billing manager"
    assert get_session(denied, :billing_intent) == token
  end

  test "a browser whose only session is dead is sent to sign in, with the choice kept", %{
    conn: conn
  } do
    {conn, _owner, account} = register_and_log_in(conn)
    Fixtures.Auth.delete_session_token!(session_token(conn, account))
    token = BillingIntent.sign("team", :year)
    captured = get(conn, ~p"/start/team/#{token}")

    bounced = get(recycle(captured), ~p"/app/billing/start")
    assert redirected_to(bounced) == ~p"/sign_in"
    assert get_session(bounced, :billing_intent) == token
    refute get_session(bounced, :sessions)
  end

  test "a browser whose only session expired gets its choice back after signing in again", %{
    conn: conn
  } do
    {conn, owner, account} = register_and_log_in(conn)
    Fixtures.Auth.delete_session_token!(session_token(conn, account))
    token = BillingIntent.sign("team", :year)
    captured = get(conn, ~p"/start/team/#{token}")
    bounced = get(recycle(captured), ~p"/app/billing/start")
    assert redirected_to(bounced) == ~p"/sign_in"

    started =
      bounced
      |> recycle()
      |> post(~p"/app/#{account}/sign_in/email", %{"user" => %{"email" => owner.email}})

    assert_received {:email, %{text_body: body}}
    [_, token_id, code] = Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", body)
    signed_in = started |> recycle() |> get(~p"/sign_in/magic/#{token_id}/#{code}")
    assert redirected_to(signed_in) == ~p"/app/billing/start"

    chooser = get(recycle(signed_in), ~p"/app/billing/start")
    assert html_response(chooser, 200) =~ account.name
    assert get_session(chooser, :billing_intent) == token
  end

  test "cancel clears the choice without changing plan", %{conn: conn} do
    {conn, _owner, _account} = register_and_log_in(conn)
    token = BillingIntent.sign("team", :month)
    captured = get(conn, ~p"/start/team/#{token}")
    canceled = post(recycle(captured), ~p"/app/billing/start/cancel")

    assert redirected_to(canceled) == ~p"/app"
    refute get_session(canceled, :billing_intent)
  end

  test "a viewer with a workspace sees a permission-empty chooser, not no workspaces", %{
    conn: conn
  } do
    {conn, owner, _account} = register_and_log_in(conn)
    Fixtures.Memberships.force_role(owner, "viewer")
    token = BillingIntent.sign("team", :month)
    captured = get(conn, ~p"/start/team/#{token}")

    chooser = get(recycle(captured), ~p"/app/billing/start")
    html = html_response(chooser, 200)
    assert html =~ "No workspaces you can upgrade"
    assert html =~ "You need billing access"
    assert get_session(chooser, :billing_intent) == token
    refute html =~ "Choose a plan again"
  end

  test "an invalid stored plan choice is cleared rather than shown as a workspace error", %{
    conn: conn
  } do
    {conn, _owner, _account} = register_and_log_in(conn)
    conn = Plug.Conn.put_session(conn, :billing_intent, "forged")
    conn = get(conn, ~p"/app/billing/start")

    assert redirected_to(conn) == ~p"/pricing"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
             "That plan selection is no longer valid"

    refute get_session(conn, :billing_intent)
  end
end
