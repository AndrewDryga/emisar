defmodule EmisarWeb.RunsLiveTest do
  @moduledoc """
  The runs list names the initiator of each run — for MCP/LLM runs that's
  the API key's name (e.g. "Claude Code"), not the bare source.
  """
  use EmisarWeb.ConnCase, async: true

  import Emisar.Fixtures

  alias Emisar.{Repo, Runs}
  alias Emisar.Runners.Runner

  test "shows the API key name in the source column", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    {_raw, key} = api_key_fixture(account_id: account.id, name: "Claude Code")

    {:ok, runner} =
      Runner.Changeset.register(%{
        account_id: account.id,
        name: "runner-1",
        external_id: Ecto.UUID.generate(),
        group: "default",
        hostname: "10.0.5.12"
      })
      |> Repo.insert()

    {:ok, _run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "mcp",
        api_key_id: key.id,
        args: %{}
      })

    {:ok, _lv, html} = live(conn, ~p"/app/runs")

    assert html =~ "Claude Code"
  end
end
