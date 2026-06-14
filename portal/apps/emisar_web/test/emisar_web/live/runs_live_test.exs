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
    # Secondary columns (Source/Duration) collapse below lg so the table fits
    # a phone in an incident.
    assert html =~ "hidden lg:table-cell"
    # The "When" timestamp renders as a hook-driven <time> (viewer-local),
    # consistent with the rest of the app — not a raw server-UTC string.
    assert html =~ ~s(phx-hook="LocalTime")
    assert html =~ ~s(data-format="relative")
  end

  test "redirects anonymous users", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/app/runs")
  end

  test "the connected empty render shows the onboarding pitch", %{conn: conn} do
    {conn, _user, _account} = register_and_log_in(conn)

    {:ok, _lv, html} = live(conn, ~p"/app/runs")
    assert html =~ "No runs yet"
  end

  test "the dead/pre-connect empty render shows a loading placeholder, not the pitch",
       %{conn: conn} do
    {conn, _user, _account} = register_and_log_in(conn)

    # A plain GET is the disconnected render — connected?/1 is false, so the
    # onboarding pitch is deferred behind a loading placeholder rather than
    # flashed before the live socket confirms the list is really empty.
    html = conn |> get(~p"/app/runs") |> html_response(200)
    assert html =~ "Loading"
    refute html =~ "No runs yet"
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
