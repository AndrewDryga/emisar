defmodule EmisarWeb.RunDetailLiveTest do
  @moduledoc """
  The run detail page surfaces the policy verdict that gated the run —
  the decision (allow / require_approval / deny) as a chip plus the
  reason — for every run, not just the ones waiting on approval.
  """
  use EmisarWeb.ConnCase, async: true

  alias Emisar.{Repo, Runs}
  alias Emisar.Runners.Runner

  defp run_with(account, attrs) do
    {:ok, runner} =
      Runner.Changeset.register(%{
        account_id: account.id,
        name: "runner-1",
        external_id: Ecto.UUID.generate(),
        group: "default",
        hostname: "10.0.5.12"
      })
      |> Repo.insert()

    {:ok, run} =
      Runs.create_run(
        Map.merge(
          %{
            account_id: account.id,
            runner_id: runner.id,
            action_id: "linux.uptime",
            source: "mcp",
            args: %{}
          },
          attrs
        )
      )

    run
  end

  test "shows the policy decision + reason", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    run =
      run_with(account, %{
        policy_decision: "require_approval",
        policy_reason: "Default for high-risk actions",
        policy_version: 4
      })

    {:ok, _lv, html} = live(conn, ~p"/app/runs/#{run.id}")

    assert html =~ "Policy"
    assert html =~ "Requires approval"
    assert html =~ "Default for high-risk actions"
    assert html =~ "policy v4"
  end

  test "omits the policy summary when no decision was recorded", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{})

    {:ok, _lv, html} = live(conn, ~p"/app/runs/#{run.id}")

    refute html =~ "Requires approval"
  end
end
