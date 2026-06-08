defmodule EmisarWeb.RunDetailLiveTest do
  @moduledoc """
  The run detail page surfaces the policy verdict that gated the run —
  the decision (allow / require_approval / deny) as a chip plus the
  reason — for every run, not just the ones waiting on approval.
  """
  use EmisarWeb.ConnCase, async: true

  import Emisar.Fixtures

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

  test "names the API key that initiated an MCP run", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    {_raw, key} = api_key_fixture(account_id: account.id, name: "Claude Code")
    run = run_with(account, %{source: "mcp", api_key_id: key.id})

    {:ok, _lv, html} = live(conn, ~p"/app/runs/#{run.id}")

    # The operator-named key is the headline initiator; the source type
    # ("MCP / LLM") trails as context.
    assert html =~ "Claude Code"
    assert html =~ "MCP / LLM"
  end

  test "prefers the MCP client name + version over a generic key name", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    {_raw, key} = api_key_fixture(account_id: account.id, name: "prod-mcp")

    run =
      run_with(account, %{
        source: "mcp",
        api_key_id: key.id,
        client_info: %{"name" => "Claude Code", "version" => "1.2.3"}
      })

    {:ok, _lv, html} = live(conn, ~p"/app/runs/#{run.id}")

    assert html =~ "Claude Code"
    assert html =~ "1.2.3"
    refute html =~ "prod-mcp"
  end

  test "renders output as a single pre with chunks as inline spans (no double spacing)",
       %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "success"})

    {:ok, _} =
      Runs.append_event(run, %{
        seq: 1,
        kind: "progress",
        stream: "stdout",
        payload: %{"chunk" => "first-line\n"}
      })

    # A non-output lifecycle event between chunks must not add a blank line.
    {:ok, _} =
      Runs.append_event(run, %{seq: 2, kind: "transition", payload: %{"to" => "running"}})

    {:ok, _} =
      Runs.append_event(run, %{
        seq: 3,
        kind: "progress",
        stream: "stderr",
        payload: %{"chunk" => "boom-error\n"}
      })

    {:ok, _lv, html} = live(conn, ~p"/app/runs/#{run.id}")

    # Terminal is one <pre>; each chunk is an inline <span> so chunks
    # concatenate and only their own newlines break lines. Stderr is
    # colored right on its span. Block wrappers / template indentation
    # here would double the spacing (the reported bug).
    assert html =~ ~r/<pre[^>]*id="run-output"/
    assert html =~ ~r/<span[^>]*>first-line/
    assert html =~ "boom-error"
    assert html =~ ~r/<span[^>]*text-rose-300[^>]*>[^<]*boom-error/
    refute html =~ ~r/<div[^>]*whitespace-pre-wrap/
  end
end
