defmodule EmisarWeb.RoleAccessMatrixTest do
  @moduledoc """
  Direct-route authorization for detail and configuration LiveViews. Every role
  gets one clean outcome: authorized roles render, while a billing-only role is
  denied without a 500 or a partial policy configuration.
  """
  use EmisarWeb.ConnCase, async: true

  @roles ~w(owner admin operator viewer billing_manager)

  setup do
    account = Fixtures.Accounts.create_account()
    owner = Fixtures.Users.create_user()

    Fixtures.Memberships.create_membership(
      account_id: account.id,
      user_id: owner.id,
      role: "owner"
    )

    runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
    run = Fixtures.Runs.create_run(account_id: account.id, runner_id: runner.id)
    approval = Fixtures.Approvals.create_request(account_id: account.id, run_id: run.id)
    Fixtures.Policies.create_policy(account_id: account.id, created_by_id: owner.id)

    role_users =
      Enum.reduce(@roles, %{"owner" => owner}, fn
        "owner", users ->
          users

        role, users ->
          user = Fixtures.Users.create_user()

          Fixtures.Memberships.create_membership(
            account_id: account.id,
            user_id: user.id,
            role: role
          )

          Map.put(users, role, user)
      end)

    %{account: account, approval: approval, role_users: role_users, runner: runner, run: run}
  end

  test "every membership role gets a clean direct-route outcome", %{
    account: account,
    approval: approval,
    role_users: role_users,
    runner: runner,
    run: run
  } do
    for role <- @roles do
      conn = log_in_user(build_conn(), role_users[role])
      authorized? = role != "billing_manager"

      assert_detail_route(
        conn,
        ~p"/app/#{account}/runners/#{runner.id}",
        ~p"/app/#{account}/runners",
        "Runner not found.",
        runner.name,
        authorized?
      )

      assert_detail_route(
        conn,
        ~p"/app/#{account}/runs/#{run.id}",
        ~p"/app/#{account}/runs",
        "Run not found.",
        run.action_id,
        authorized?
      )

      assert_detail_route(
        conn,
        ~p"/app/#{account}/approvals/#{approval.id}",
        ~p"/app/#{account}/approvals",
        "Approval not found.",
        "Approval",
        authorized?
      )

      assert_page_route(
        conn,
        ~p"/app/#{account}/settings/team",
        ~p"/app/#{account}",
        "You don't have access to team.",
        "Members",
        authorized?
      )

      assert_page_route(
        conn,
        ~p"/app/#{account}/policies",
        ~p"/app/#{account}",
        "You don't have access to policies.",
        "Default policy",
        authorized?
      )
    end
  end

  defp assert_detail_route(conn, path, denied_path, denied_message, marker, authorized?) do
    assert_route(conn, path, denied_path, denied_message, marker, authorized?)
  end

  defp assert_page_route(conn, path, denied_path, denied_message, marker, authorized?) do
    assert_route(conn, path, denied_path, denied_message, marker, authorized?)
  end

  defp assert_route(conn, path, denied_path, denied_message, marker, authorized?) do
    result = live(conn, path)

    if authorized? do
      assert {:ok, _lv, html} = result
      assert html =~ marker
    else
      assert {:error, {:live_redirect, %{to: ^denied_path, flash: flash}}} = result
      assert flash["error"] == denied_message
    end
  end
end
