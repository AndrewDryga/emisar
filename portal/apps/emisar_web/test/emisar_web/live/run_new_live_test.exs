defmodule EmisarWeb.RunNewLiveTest do
  @moduledoc """
  The run-dispatch form's inputs are generated from the selected action's
  argument spec. Bad or missing args must render inline under the offending
  field (rose border, message beneath it), not in a flash banner.
  """
  use EmisarWeb.ConnCase, async: true

  import Emisar.Fixtures

  defp action_with_required_arg(account) do
    runner = runner_fixture(account_id: account.id)

    action =
      action_fixture(
        runner: runner,
        action_id: "linux.tail_log",
        args_schema: %{
          "args" => [
            %{
              "name" => "path",
              "type" => "string",
              "required" => true,
              "description" => "Absolute path to the log file"
            }
          ]
        }
      )

    {runner, action}
  end

  test "missing required arg renders inline on the field, not in a flash", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    {runner, action} = action_with_required_arg(account)

    {:ok, lv, _html} =
      live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    # Required `path` left blank; reason is filled so we exercise the arg
    # validation, not the reason guard.
    html =
      lv
      |> form("#dispatch_form", %{
        "args" => %{"path" => ""},
        "reason" => "checking the access log"
      })
      |> render_submit()

    # Inline field error rendered by <.input>/<.error> under the `path` input…
    assert html =~ "path is required"
    # …and not the old humanized flash banner.
    refute html =~ "Invalid:"
  end

  test "an enforcing runner replaces the Dispatch button with a signed-only notice", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    runner = runner_fixture(account_id: account.id, enforce_signatures: true, connected?: true)
    action = action_fixture(runner: runner, action_id: "linux.uptime")

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    assert html =~ "Signed dispatch only"
    assert html =~ "run it from your MCP client"
    # No Dispatch submit — the run would be refused at the runner.
    refute html =~ "Dispatch to runner"
  end

  test "live validation surfaces an inline error once the field is touched", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    {runner, action} = action_with_required_arg(account)

    {:ok, lv, _html} =
      live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    html =
      lv
      |> form("#dispatch_form", %{"args" => %{"path" => ""}, "reason" => ""})
      |> render_change()

    assert html =~ "path is required"
    refute html =~ "Invalid:"
  end

  test "an unknown action bounces back to the runner page", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    runner = runner_fixture(account_id: account.id)

    assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
             live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/no.such_action")

    assert to == ~p"/app/#{account}/runners/#{runner.id}"
    assert flash["error"] == "Action not found."
  end

  test "a blank reason refuses to dispatch", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    _ = policy_fixture(account_id: account.id, created_by_id: user.id)
    {runner, action} = action_with_required_arg(account)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    html =
      lv
      |> form("#dispatch_form", %{"args" => %{"path" => "/var/log/app.log"}, "reason" => "  "})
      |> render_submit()

    assert html =~ "Reason is required"
  end

  test "a valid dispatch navigates to the run detail page", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    _ = policy_fixture(account_id: account.id, created_by_id: user.id)
    {runner, action} = action_with_required_arg(account)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    lv
    |> form("#dispatch_form", %{
      "args" => %{"path" => "/var/log/app.log"},
      "reason" => "tailing the access log"
    })
    |> render_submit()

    {path, _flash} = assert_redirect(lv)
    assert path =~ ~r{^/app/#{account.slug}/runs/[0-9a-f-]+$}
  end

  test "a policy denial is a flash, and no run is dispatched", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)

    # Deny everything at every risk tier.
    _ =
      policy_fixture(
        account_id: account.id,
        created_by_id: user.id,
        rules: %{
          "defaults" => %{
            "low" => "deny",
            "medium" => "deny",
            "high" => "deny",
            "critical" => "deny"
          }
        }
      )

    {runner, action} = action_with_required_arg(account)

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    html =
      lv
      |> form("#dispatch_form", %{
        "args" => %{"path" => "/var/log/app.log"},
        "reason" => "should be denied"
      })
      |> render_submit()

    assert html =~ "Denied by policy"
  end

  test "a viewer cannot dispatch at the event level", %{conn: conn} do
    {_owner_conn, _owner, account} = register_and_log_in(conn)
    {runner, action} = action_with_required_arg(account)

    viewer = user_fixture()
    _ = membership_fixture(account_id: account.id, user_id: viewer.id, role: "viewer")

    {:ok, lv, _html} =
      build_conn()
      |> log_in_user(viewer)
      |> live(~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    html =
      lv
      |> form("#dispatch_form", %{
        "args" => %{"path" => "/var/log/app.log"},
        "reason" => "viewer trying anyway"
      })
      |> render_submit()

    assert html =~ "You don&#39;t have permission to do that."
  end

  test "a high-risk action's dispatch button asks for confirmation", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    runner = runner_fixture(account_id: account.id)
    action = action_fixture(runner: runner, action_id: "linux.reboot", risk: "critical")

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    assert has_element?(lv, "button[data-confirm]")
    assert render(lv) =~ "runs on the host immediately"
  end

  test "a high-risk confirm folds in the entered args (the blast radius)", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    runner = runner_fixture(account_id: account.id)

    action =
      action_fixture(
        runner: runner,
        action_id: "linux.tail_log",
        risk: "high",
        args_schema: %{
          "args" => [
            %{
              "name" => "path",
              "type" => "string",
              "required" => true,
              "description" => "Log path"
            }
          ]
        }
      )

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    # Type a path → the confirm must echo it so the operator confirms WHAT
    # runs (which file), not just the action name.
    html =
      lv
      |> form("#dispatch_form", %{"args" => %{"path" => "/var/log/auth.log"}, "reason" => "x"})
      |> render_change()

    assert html =~ "path: /var/log/auth.log"
  end

  test "a low-risk action's dispatch button does not confirm", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    runner = runner_fixture(account_id: account.id)
    action = action_fixture(runner: runner, action_id: "linux.uptime", risk: "low")

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    assert has_element?(lv, "button", "Dispatch to runner")
    refute has_element?(lv, "button[data-confirm]")
  end

  test "an offline runner warns the run will queue", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    runner = runner_fixture(account_id: account.id, connected?: false)
    action = action_fixture(runner: runner, action_id: "linux.uptime")

    # The runner is only looked up on the connected render, so assert
    # against render/1.
    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")
    html = render(lv)

    assert html =~ "Runner offline"
    assert html =~ "queues as"
  end

  test "a viewer sees a note instead of the dispatch button", %{conn: conn} do
    {_owner_conn, _owner, account} = register_and_log_in(conn)
    runner = runner_fixture(account_id: account.id)
    action = action_fixture(runner: runner, action_id: "linux.uptime")

    viewer = user_fixture()
    _ = membership_fixture(account_id: account.id, user_id: viewer.id, role: "viewer")

    {:ok, lv, html} =
      build_conn()
      |> log_in_user(viewer)
      |> live(~p"/app/#{account}/runs/new/#{runner.id}/#{action.action_id}")

    refute has_element?(lv, "button", "Dispatch to runner")
    assert html =~ "Your role can&#39;t dispatch runs"
  end
end
