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
  alias Emisar.Runs.RunEvent

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

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert html =~ "Policy"
    assert html =~ "Requires approval"
    assert html =~ "Default for high-risk actions"
    assert html =~ "v4"
  end

  test "a denied run surfaces the denial + reason, not a bare cancellation", %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)

    run = run_with(account, %{})
    {:ok, request} = Emisar.Approvals.create_request(run, user.id, "deploy")

    {:ok, _} =
      Emisar.Approvals.deny_request(
        request,
        owner_subject(user, account),
        "not during the change freeze"
      )

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    # The run lands :cancelled, but the requester must see WHY — the denial
    # reason the approver typed (stored on the run as "approval denied: …") —
    # not a bare grey badge.
    assert html =~ "Cancelled"
    assert html =~ "approval denied: not during the change freeze"
  end

  test "omits the policy summary when no decision was recorded", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{})

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    refute html =~ "Requires approval"
  end

  test "names the API key that initiated an MCP run", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    {_raw, key} = api_key_fixture(account_id: account.id, name: "Claude Code")
    run = run_with(account, %{source: "mcp", api_key_id: key.id})

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

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

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert html =~ "Claude Code"
    assert html =~ "1.2.3"
    refute html =~ "prod-mcp"
  end

  test "shows the MCP session id as a sub-line under Source, not its own cell", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    {_raw, key} = api_key_fixture(account_id: account.id, name: "Claude Code")

    run =
      run_with(account, %{
        source: "mcp",
        api_key_id: key.id,
        mcp_session_id: "5985d95cab127f30"
      })

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    # The truncated id rides under the Source cell (full id on hover); the
    # standalone "MCP session" meta cell is gone.
    assert html =~ "session 5985d95c"
    assert html =~ ~s(title="5985d95cab127f30")
    refute html =~ "MCP session"
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

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

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

  # (IL-16) — runner output is attacker-influenced; a chunk
  # carrying HTML must render ESCAPED via the `event_chunk` span interpolation,
  # never `raw/1`. Asserting the literal `<script>` is absent and the escaped
  # entity is present proves no stored XSS.
  test "attacker-influenced output is HTML-escaped (no stored XSS)", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "success"})

    {:ok, _} =
      Runs.append_event(run, %{
        seq: 1,
        kind: "progress",
        stream: "stdout",
        payload: %{"chunk" => "<script>alert('xss')</script>\n"}
      })

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    # The raw tag never reaches the DOM…
    refute html =~ "<script>alert('xss')</script>"
    # …it's escaped (the renderer interpolates, it doesn't `raw/1`).
    assert html =~ "&lt;script&gt;"
  end

  # the output panel renders a BOUNDED, streamed slice
  # (`phx-update="stream"`, IL-18), never an unbounded assign of every event. The
  # mount requests `page: [limit: 500]`, but `Repo.list` hard-caps the page at
  # @max_limit (100), so the effective render cap is the first 100 events: seq-100
  # renders, seq-101 (the next page) does not. (The catalog's "capped at 500" is
  # the requested limit; the paginator's max is the real ceiling — see the note in
  # the agent report.)
  test "the output panel renders a bounded, streamed event slice (not unbounded)", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "success"})

    now = DateTime.utc_now()

    rows =
      for seq <- 1..101 do
        %{
          id: Repo.generate_id(),
          run_id: run.id,
          account_id: account.id,
          seq: seq,
          kind: :progress,
          stream: "stdout",
          payload: %{"chunk" => "chunk-#{seq}\n"},
          inserted_at: now
        }
      end

    {101, _} = Repo.insert_all(RunEvent, rows)

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    # The output is a streamed <pre> (bounded), not a plain assign of all rows.
    assert has_element?(lv, "pre#run-output[phx-update=\"stream\"]")

    # The first page (oldest 100) renders; the 101st is over the page cap.
    assert html =~ "chunk-100\n"
    refute html =~ "chunk-101\n"
  end

  test "an unknown run id bounces to the runs index", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    dest = ~p"/app/#{account}/runs"

    assert {:error, {:live_redirect, %{to: ^dest, flash: flash}}} =
             live(conn, ~p"/app/#{account}/runs/#{Ecto.UUID.generate()}")

    assert flash["error"] == "Run not found."
  end

  test "a cross-account run reads as not-found", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    foreign_account = account_fixture()
    foreign_run = run_with(foreign_account, %{})

    dest = ~p"/app/#{account}/runs"

    assert {:error, {:live_redirect, %{to: ^dest}}} =
             live(conn, ~p"/app/#{account}/runs/#{foreign_run.id}")
  end

  test "cancel sends the cancellation and confirms", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "sent"})

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    html = render_click(lv, "cancel", %{})
    assert html =~ "Cancel sent to runner."
  end

  # when cancel_run returns a non-:ok (here the run row
  # vanished between render and the cancel click), the handler flashes "Unable
  # to cancel." instead of crashing.
  test "a cancel that fails surfaces an 'Unable to cancel.' flash", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "pending"})

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    # The run is deleted out from under the page; cancel's locked re-read then
    # finds no row → {:error, :not_found} → the failure flash.
    Repo.delete!(run)

    html = render_click(lv, "cancel", %{})
    assert html =~ "Unable to cancel."
  end

  test "a viewer cannot cancel", %{conn: conn} do
    {_owner_conn, _owner, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "sent"})

    viewer = user_fixture()
    _ = membership_fixture(account_id: account.id, user_id: viewer.id, role: "viewer")

    {:ok, lv, _html} =
      build_conn() |> log_in_user(viewer) |> live(~p"/app/#{account}/runs/#{run.id}")

    html = render_click(lv, "cancel", %{})
    assert html =~ "You don&#39;t have permission to do that."
    assert Repo.reload!(run).status == :sent
  end

  test "a run_event broadcast streams into the live terminal", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "running"})

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")
    refute html =~ "late-chunk"

    {:ok, event} =
      Runs.append_event(run, %{
        seq: 1,
        kind: "progress",
        stream: "stdout",
        payload: %{"chunk" => "late-chunk\n"}
      })

    send(lv.pid, {:run_event, event})
    assert render(lv) =~ "late-chunk"
  end

  test "an errored run that produced no output hides the empty terminal", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "sent"})

    {:ok, _} =
      Runs.finalize_from_result(run.runner_id, %{
        "request_id" => run.request_id,
        "status" => "error",
        "error" => "runner disconnected, result never arrived"
      })

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert html =~ "runner disconnected, result never arrived"
    refute html =~ "Output"
  end

  test "an errored run that DID produce output keeps the panel", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "running"})

    {:ok, _} =
      Runs.append_event(run, %{
        seq: 1,
        kind: "progress",
        stream: "stdout",
        payload: %{"chunk" => "partial-line\n"}
      })

    {:ok, _} =
      Runs.finalize_from_result(run.runner_id, %{
        "request_id" => run.request_id,
        "status" => "error",
        "error" => "boom"
      })

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert html =~ "Output"
    assert html =~ "partial-line"
  end

  test "a run_updated broadcast refreshes the status chip", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "sent"})

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    {:ok, updated} =
      Runs.finalize_from_result(run.runner_id, %{
        "request_id" => run.request_id,
        "status" => "success",
        "exit_code" => 0
      })

    send(lv.pid, {:run_updated, updated})

    assert render(lv) =~ "success"
  end

  test "a refused run surfaces the reason and hides the (never-produced) output panel", %{
    conn: conn
  } do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "sent"})

    {:ok, _} =
      Runs.finalize_from_result(run.runner_id, %{
        "request_id" => run.request_id,
        "status" => "signature_invalid",
        "reason" => "bad_signature",
        "error" => "refused: signature does not match the dispatched action"
      })

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    # The distinct terminal state + the human refusal reason both show…
    assert html =~ "refused"
    assert html =~ "refused: signature does not match the dispatched action"
    # …and there's no empty terminal panel (a refused run produced no output).
    refute html =~ "Output"
  end

  test "the cancel button renders for an in-flight run (status compared as an atom)", %{
    conn: conn
  } do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "sent"})

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    # Regression: the button's `status in [...]` guard compared the Ecto.Enum
    # atom against strings, so it never rendered.
    assert html =~ "Cancel run"
  end

  test "an in-flight run whose runner is offline shows the disconnected banner", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    # run_with's runner is registered but never tracked in presence → offline.
    run = run_with(account, %{status: "running"})

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert html =~ "Runner disconnected"
  end

  test "a queued run whose runner is offline explains why it's stuck", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    # Offline runner (registered, never in presence) + a not-yet-dispatched run.
    run = run_with(account, %{status: "pending"})

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert html =~ "Queued — runner offline"
    # The in-flight banner's copy would be wrong for a run that hasn't dispatched.
    refute html =~ "output may be incomplete"
  end

  test "an in-flight run on a connected runner shows no disconnect banner", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    runner = runner_fixture(account_id: account.id, connected?: true)
    run = run_with(account, %{status: "running", runner_id: runner.id})

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    refute html =~ "Runner disconnected"
  end

  test "shows a streaming pill while in flight, gone once terminal", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "running"})

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")
    assert html =~ "streaming"

    {:ok, finished} =
      Runs.finalize_from_result(run.runner_id, %{
        "request_id" => run.request_id,
        "status" => "success",
        "exit_code" => 0
      })

    send(lv.pid, {:run_updated, finished})
    refute render(lv) =~ "streaming"
  end
end
