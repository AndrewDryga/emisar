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
    {conn, _user, account} = register_and_log_in(conn)
    token = BillingIntent.sign("team", :month)

    captured = get(conn, ~p"/start/team/#{token}")
    assert redirected_to(captured) == ~p"/app/billing/start"

    chooser = get(recycle(captured), ~p"/app/billing/start")
    html = html_response(chooser, 200)

    assert html =~ "Choose a workspace"
    assert html =~ "Monthly billing"
    assert html =~ "Review Team for #{account.name}"
    refute account.paddle_customer_id
  end

  test "a multi-account operator explicitly selects and pins the billed workspace", %{conn: conn} do
    {conn, user, account_a} = register_and_log_in(conn)
    account_b = Fixtures.Accounts.create_account(%{name: "Billing Target"})

    Fixtures.Memberships.create_membership(
      account_id: account_b.id,
      user_id: user.id,
      role: "owner"
    )

    token = BillingIntent.sign("team", :year)
    captured = get(conn, ~p"/start/team/#{token}")
    chooser = get(recycle(captured), ~p"/app/billing/start")
    html = html_response(chooser, 200)

    assert html =~ "Review Team for #{account_a.name}"
    assert html =~ "Review Team for Billing Target"

    selected =
      chooser
      |> recycle()
      |> post(~p"/app/billing/start", %{"account_id" => account_b.id})

    assert redirected_to(selected) ==
             ~p"/app/#{account_b}/settings/billing?billing_intent=#{token}"

    assert get_session(selected, :current_account_id) == account_b.id
    refute get_session(selected, :billing_intent)
  end

  test "a non-billing membership cannot select that workspace", %{conn: conn} do
    {conn, user, account_a} = register_and_log_in(conn)
    account_b = Fixtures.Accounts.create_account(%{name: "Viewer Space"})

    Fixtures.Memberships.create_membership(
      account_id: account_b.id,
      user_id: user.id,
      role: "viewer"
    )

    token = BillingIntent.sign("team", :month)
    conn = Plug.Conn.put_session(conn, :current_account_id, account_a.id)
    captured = get(conn, ~p"/start/team/#{token}")

    chooser = get(recycle(captured), ~p"/app/billing/start")
    html = html_response(chooser, 200)
    assert html =~ "Review Team for #{account_a.name}"
    refute html =~ "Review Team for Viewer Space"

    denied =
      captured
      |> recycle()
      |> post(~p"/app/billing/start", %{"account_id" => account_b.id})

    html = html_response(denied, 200)
    assert html =~ "Only an owner, admin, or billing manager"
    assert get_session(denied, :current_account_id) == account_a.id
    assert get_session(denied, :billing_intent) == token
  end

  test "a foreign account id is denied without changing the current workspace", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    foreign = Fixtures.Accounts.create_account()
    token = BillingIntent.sign("team", :month)
    captured = get(conn, ~p"/start/team/#{token}")

    denied =
      captured
      |> recycle()
      |> post(~p"/app/billing/start", %{"account_id" => foreign.id})

    assert html_response(denied, 200) =~ "Only an owner, admin, or billing manager"
    assert get_session(denied, :current_account_id) == account.id
  end

  test "a signed-in user with no membership reaches onboarding with intent intact", %{conn: conn} do
    conn = log_in_user(conn, Fixtures.Users.create_user())
    token = BillingIntent.sign("team", :year)
    captured = get(conn, ~p"/start/team/#{token}")

    bounced = get(recycle(captured), ~p"/app/billing/start")
    assert redirected_to(bounced) == ~p"/onboarding"
    assert get_session(bounced, :billing_intent) == token
  end

  test "cancel clears the choice without changing plan", %{conn: conn} do
    {conn, _user, _account} = register_and_log_in(conn)
    token = BillingIntent.sign("team", :month)
    captured = get(conn, ~p"/start/team/#{token}")
    canceled = post(recycle(captured), ~p"/app/billing/start/cancel")

    assert redirected_to(canceled) == ~p"/app"
    refute get_session(canceled, :billing_intent)
  end
end
