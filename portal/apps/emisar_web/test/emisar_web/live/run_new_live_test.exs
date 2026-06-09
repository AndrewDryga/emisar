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
end
