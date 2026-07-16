defmodule EmisarWeb.RunDetailLiveTest do
  @moduledoc """
  The run detail page surfaces the policy verdict that gated the run —
  the decision (allow / require_approval / deny) as a chip plus the
  reason — for every run, not just the ones waiting on approval.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Repo, Runs}
  alias Emisar.Runs.RunEvent

  defp run_with(account, attrs) do
    runner_id =
      attrs[:runner_id] ||
        Fixtures.Runners.create_runner(
          account_id: account.id,
          name: "runner-1",
          group: "default",
          hostname: "10.0.5.12",
          connected?: Map.get(attrs, :runner_connected?, true)
        ).id

    attrs = Map.delete(attrs, :runner_connected?)

    {:ok, run} =
      Runs.create_run(
        Map.merge(
          %{
            account_id: account.id,
            runner_id: runner_id,
            action_id: "linux.uptime",
            source: "mcp",
            args: %{}
          },
          attrs
        )
      )

    run
  end

  test "View activity links the dispatch's request_id trace", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{})

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    # Run events target the RUNNER, so the run's trail is its request_id trace
    # (transitions + grant use + cancel), not a target filter.
    assert html =~ "View activity"
    assert html =~ ~s(request_id=#{run.request_id})
    refute html =~ "target_kind=action_run"
    refute html =~ "target_id=#{run.id}"
  end

  test "the policy panel carries the WHY, not a verdict chip (told once by status)",
       %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    run =
      run_with(account, %{
        policy_decision: "require_approval",
        policy_reason: "Default for high-risk actions",
        policy_version: 4
      })

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    # Eyebrow + the reason (the WHY) + the audit trail (matched rules / version).
    assert html =~ "Policy"
    assert html =~ "Default for high-risk actions"
    assert html =~ "v4"
    # The verdict word is NOT restated as a chip — the run's status badge is the
    # single source of the outcome.
    refute html =~ "Requires approval"
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

  test "an MCP run leads with the accountable human, key as via context", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    owner = Fixtures.Users.create_user(full_name: "Jordan Vale")

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

    {_raw, key} =
      Fixtures.ApiKeys.create_api_key(
        account_id: account.id,
        name: "Claude Code",
        created_by_id: owner.id
      )

    run = run_with(account, %{source: "mcp", api_key_id: key.id})

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    # The accountable human (the key's owner) leads; the operator-named key
    # trails as "via" context.
    assert html =~ "Jordan Vale"
    assert html =~ "via Claude Code"
  end

  test "the channel is the operator-named key + the client version, not the client name",
       %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    {_raw, key} = Fixtures.ApiKeys.create_api_key(account_id: account.id, name: "prod-mcp")

    run =
      run_with(account, %{
        source: "mcp",
        api_key_id: key.id,
        client_info: %{"name" => "Claude Code", "version" => "1.2.3"}
      })

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    # The operator-named key IS the channel ("via prod-mcp"); the snapshotted
    # client version rides along — but the self-reported client NAME is not the
    # attribution channel.
    assert html =~ "via prod-mcp"
    assert html =~ "1.2.3"
    refute html =~ "Claude Code"
  end

  test "renders self-reported client metadata, labeled as not verified posture", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    run =
      run_with(account, %{
        source: "mcp",
        mcp_client_metadata: %{"asset_tag" => "LT-4417", "device_id" => "d-99"}
      })

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert html =~ "Client metadata"
    assert html =~ "asset_tag"
    assert html =~ "LT-4417"
    assert html =~ "device_id"
    # Explicitly self-reported, never presented as verified device posture.
    assert html =~ "not verified device posture"
  end

  test "hides the client-metadata block for a run with none", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{source: "mcp"})

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    refute html =~ "Client metadata"
  end

  test "marks an executed command that the runner truncated", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "sent"})

    {:ok, _} =
      Fixtures.Runs.finish(run, %{
        "request_id" => run.request_id,
        "status" => "success",
        "exit_code" => 0,
        "executed_command" => "printf [REDACTED]",
        "executed_command_truncated" => true
      })

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert html =~ "Executed command"
    assert html =~ "truncated · secrets redacted"
  end

  test "keeps the complete executed-command annotation quiet", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "sent"})

    {:ok, _} =
      Fixtures.Runs.finish(run, %{
        "request_id" => run.request_id,
        "status" => "success",
        "exit_code" => 0,
        "executed_command" => "uptime -p"
      })

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert html =~ "secrets redacted"
    refute html =~ "truncated · secrets redacted"
  end

  test "warns when the runner could not persist its terminal audit event", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "sent"})

    {:ok, _} =
      Fixtures.Runs.finish(run, %{
        "request_id" => run.request_id,
        "status" => "success",
        "exit_code" => 0,
        "local_audit_failed" => true
      })

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert html =~ "hero-document-minus"
    assert html =~ "Runner audit record incomplete"
    assert html =~ "audit storage before relying on its local journal"
  end

  test "does not show a runner audit warning for a healthy terminal result", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "sent"})

    {:ok, _} =
      Fixtures.Runs.finish(run, %{
        "request_id" => run.request_id,
        "status" => "success",
        "exit_code" => 0
      })

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    refute html =~ "Runner audit record incomplete"
    refute html =~ "audit storage before relying on its local journal"
  end

  # Metadata keys/values are attacker-influenced (a hostile MCP client controls
  # them), so they must render ESCAPED — never via raw/1 (IL-16).
  test "escapes attacker-influenced client metadata (no stored XSS)", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    run =
      run_with(account, %{
        source: "mcp",
        mcp_client_metadata: %{"asset_tag" => "<script>alert(1)</script>"}
      })

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    refute html =~ "<script>alert(1)</script>"
    assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
  end

  test "renders output as a single pre with chunks as inline spans (no double spacing)",
       %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    # Progress arrives while the run is live; append rejects terminal runs.
    run = run_with(account, %{status: "running"})

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
    # Progress arrives while the run is live; append rejects terminal runs.
    run = run_with(account, %{status: "running"})

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
  # (`phx-update="stream"`, IL-18), never an unbounded assign of every event.
  # Mount loads the most-recent @event_window (500) progress chunks in seq order
  # (`Runs.list_recent_events_for_run/3`) — the same window the live stream
  # converges to via `stream_insert(limit: -500)` — so with 501 chunks the
  # newest 500 render and the oldest falls outside the window.
  test "the output panel renders a bounded, streamed event slice (not unbounded)", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "success"})

    now = DateTime.utc_now()

    rows =
      for seq <- 1..501 do
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

    {501, _} = Repo.insert_all(RunEvent, rows)

    {:ok, lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    # The output is a streamed <pre> (bounded), not a plain assign of all rows.
    assert has_element?(lv, "pre#run-output[phx-update=\"stream\"]")

    # The most-recent 500 render (seq 2..501); the oldest is outside the window.
    assert html =~ "chunk-2\n"
    assert html =~ "chunk-501\n"
    refute html =~ "chunk-1\n"
  end

  # A live-appending stream never evicts on its own, so a chatty run would grow
  # the viewer's DOM one node per chunk without bound. stream_insert's :limit
  # caps the client at the most-recent 500 events: the newest chunk renders, one
  # well past the 500-event window (evicted as newer chunks arrive) does not.
  test "the live event stream is client-bounded (a chatty run can't grow the DOM without bound)",
       %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "running"})

    {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    for seq <- 1..600 do
      event = %RunEvent{
        id: Repo.generate_id(),
        run_id: run.id,
        account_id: account.id,
        seq: seq,
        kind: :progress,
        stream: "stdout",
        payload: %{"chunk" => "chunk-#{seq}\n"}
      }

      send(lv.pid, {:run_event, event})
    end

    html = render(lv)

    # The last 500 (seq 101..600) are retained; seq 50 was evicted.
    assert html =~ "chunk-600\n"
    refute html =~ "chunk-50\n"
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

    foreign_account = Fixtures.Accounts.create_account()
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
    assert html =~ "Cancellation accepted."
    assert html =~ "Cancellation requested"
    assert Repo.reload!(run).status == :cancelling
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

    viewer = Fixtures.Users.create_user()

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

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
      Fixtures.Runs.finish(run, %{
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
      Fixtures.Runs.finish(run, %{
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
      Fixtures.Runs.finish(run, %{
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
      Fixtures.Runs.finish(run, %{
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
    run = run_with(account, %{status: "running", runner_connected?: false})

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert html =~ "Runner disconnected"
  end

  test "a queued run whose runner is offline explains why it's stuck", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    run = run_with(account, %{status: "pending", runner_connected?: false})

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runs/#{run.id}")

    assert html =~ "Queued — runner offline"
    # The in-flight banner's copy would be wrong for a run that hasn't dispatched.
    refute html =~ "output may be incomplete"
  end

  test "an in-flight run on a connected runner shows no disconnect banner", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)
    runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)
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
      Fixtures.Runs.finish(run, %{
        "request_id" => run.request_id,
        "status" => "success",
        "exit_code" => 0
      })

    send(lv.pid, {:run_updated, finished})
    refute render(lv) =~ "streaming"
  end
end
