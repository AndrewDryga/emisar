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

  test "redirects anonymous users", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/app/runs")
  end

  test "renders the empty state before any runs exist", %{conn: conn} do
    {conn, _user, _account} = register_and_log_in(conn)

    {:ok, _lv, html} = live(conn, ~p"/app/runs")
    assert html =~ "Runs"
  end

  test "an account-runs broadcast reloads the current page", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    runner = runner_fixture(account_id: account.id, connected?: false)

    {:ok, lv, html} = live(conn, ~p"/app/runs")
    refute html =~ "linux.late_run"

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.late_run",
        source: "operator",
        args: %{}
      })

    send(lv.pid, {:run_created, run})
    assert render(lv) =~ "linux.late_run"

    # The badge hooks forward unrelated account-topic broadcasts — any
    # other message shape is ignored, never a crash.
    send(lv.pid, :totally_unrelated)
    assert render(lv) =~ "linux.late_run"
  end

  test "a bad cursor in the URL falls back to the first page", %{conn: conn} do
    {conn, _user, _account} = register_and_log_in(conn)

    {:ok, _lv, html} = live(conn, ~p"/app/runs?page=garbage-cursor")
    assert html =~ "Runs"
  end
end
