defmodule EmisarWeb.RoleAccessMatrixTest do
  @moduledoc """
  Direct-route authorization for detail and configuration LiveViews. Every role
  gets one clean outcome: authorized roles render, while a billing-only role is
  denied without a 500 or a partial policy configuration.

  Team and Audit are the two routes EVERY membership role reaches — the roster
  because every member may see who they work with, Audit because the finance
  seat gets the billing slice of it (`Audit.Authorizer.for_subject/2` narrows
  the rows; the door is open to all).
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

      assert_route(
        conn,
        ~p"/app/#{account}/policies",
        ~p"/app/#{account}",
        "You don't have access to policies.",
        "Default policy",
        authorized?
      )

      # Open to every role, billing manager included — no flash, no bounce.
      assert {:ok, _team_lv, team_html} = live(conn, ~p"/app/#{account}/settings/team")
      assert team_html =~ "Members"

      assert {:ok, _audit_lv, audit_html} = live(conn, ~p"/app/#{account}/audit")
      assert audit_html =~ "Audit log"
    end
  end

  defp assert_detail_route(conn, path, denied_path, denied_message, marker, authorized?) do
    assert_route(conn, path, denied_path, denied_message, marker, authorized?)
  end

  defp assert_route(conn, path, denied_path, denied_message, marker, authorized?) do
    result = live(conn, path)

    if authorized? do
      assert {:ok, _lv, html} = result
      assert html =~ marker
    else
      assert {:error, {:live_redirect, %{to: ^denied_path, flash: flash}}} = result
      assert flash_message(flash, "error") == denied_message
    end
  end

  # A redirect from the disconnected mount carries the decoded map. One from
  # the connected mount carries LiveView's signed handoff token; both are the
  # same browser-visible flash and the route matrix should verify that contract,
  # not depend on which mount discovered the denial.
  defp flash_message(flash, key) when is_map(flash), do: flash[key]

  defp flash_message(flash, key) when is_binary(flash) do
    EmisarWeb.Endpoint
    |> Phoenix.LiveView.Utils.verify_flash(flash)
    |> Map.get(key)
  end
end
