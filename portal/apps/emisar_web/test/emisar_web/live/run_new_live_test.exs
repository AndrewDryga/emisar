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
      live(conn, ~p"/app/runs/new/#{runner.id}/#{action.action_id}")

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

  test "live validation surfaces an inline error once the field is touched", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    {runner, action} = action_with_required_arg(account)

    {:ok, lv, _html} =
      live(conn, ~p"/app/runs/new/#{runner.id}/#{action.action_id}")

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
             live(conn, ~p"/app/runs/new/#{runner.id}/no.such_action")

    assert to == "/app/runners/#{runner.id}"
    assert flash["error"] == "Action not found."
  end

  test "a blank reason refuses to dispatch", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    _ = policy_fixture(account_id: account.id, created_by_id: user.id)
    {runner, action} = action_with_required_arg(account)

    {:ok, lv, _html} = live(conn, ~p"/app/runs/new/#{runner.id}/#{action.action_id}")

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

    {:ok, lv, _html} = live(conn, ~p"/app/runs/new/#{runner.id}/#{action.action_id}")

    lv
    |> form("#dispatch_form", %{
      "args" => %{"path" => "/var/log/app.log"},
      "reason" => "tailing the access log"
    })
    |> render_submit()

    {path, _flash} = assert_redirect(lv)
    assert path =~ ~r{^/app/runs/[0-9a-f-]+$}
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

    {:ok, lv, _html} = live(conn, ~p"/app/runs/new/#{runner.id}/#{action.action_id}")

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
      |> live(~p"/app/runs/new/#{runner.id}/#{action.action_id}")

    html =
      lv
      |> form("#dispatch_form", %{
        "args" => %{"path" => "/var/log/app.log"},
        "reason" => "viewer trying anyway"
      })
      |> render_submit()

    assert html =~ "You don&#39;t have permission to do that."
  end
end
