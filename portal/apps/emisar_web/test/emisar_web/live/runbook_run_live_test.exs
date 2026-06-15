defmodule EmisarWeb.RunbookRunLiveTest do
  use EmisarWeb.ConnCase, async: true

  defp published_runbook!(user, account) do
    subject = owner_subject(user, account)

    {:ok, runbook} =
      Emisar.Runbooks.create_runbook(
        %{
          "title" => "EU health",
          "name" => "EU health",
          "slug" => "eu-health",
          "definition" => %{
            "steps" => [
              %{
                "id" => "uptime",
                "action_id" => "linux.uptime",
                "args" => %{},
                "runner_selector" => %{"group" => ["default"]}
              }
            ]
          }
        },
        subject
      )

    {:ok, runbook} = Emisar.Runbooks.publish(runbook, subject)
    runbook
  end

  # A published runbook whose lone step targets `runner` by id (so it
  # dispatches even when that runner is offline — group selectors skip
  # offline members, a runner-id selector passes through).
  defp published_runbook_targeting!(user, account, runner) do
    subject = owner_subject(user, account)

    {:ok, runbook} =
      Emisar.Runbooks.create_runbook(
        %{
          "title" => "targeted",
          "name" => "targeted",
          "slug" => "targeted",
          "definition" => %{
            "steps" => [
              %{
                "id" => "uptime",
                "action_id" => "linux.uptime",
                "args" => %{},
                "runner_selector" => %{"runner_id" => [runner.id]}
              }
            ]
          }
        },
        subject
      )

    {:ok, runbook} = Emisar.Runbooks.publish(runbook, subject)
    runbook
  end

  # N steps each targeting `runner` by id → N work-list items, so the engine
  # dispatches the first wave (@batch_size = 5) and the rest stay planned.
  defp published_runbook_with_steps!(user, account, runner, n) do
    subject = owner_subject(user, account)

    steps =
      for i <- 1..n do
        %{
          "id" => "step#{i}",
          "action_id" => "linux.uptime",
          "args" => %{},
          "runner_selector" => %{"runner_id" => [runner.id]}
        }
      end

    {:ok, runbook} =
      Emisar.Runbooks.create_runbook(
        %{
          "title" => "many steps",
          "name" => "many steps",
          "slug" => "many-steps",
          "definition" => %{"steps" => steps}
        },
        subject
      )

    {:ok, runbook} = Emisar.Runbooks.publish(runbook, subject)
    runbook
  end

  describe "dispatch + live results" do
    test "the whole plan renders up front as a static list of planned rows", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      runner = Emisar.Fixtures.runner_fixture(account_id: account.id)
      Emisar.Fixtures.action_fixture(runner: runner, action_id: "linux.uptime")
      Emisar.Fixtures.policy_fixture(account_id: account.id)
      runbook = published_runbook_with_steps!(user, account, runner, 6)

      {:ok, lv, _} = live(conn, ~p"/app/runbooks/#{runbook.id}/run")
      html = render_submit(lv, "dispatch", %{"reason" => "go"})

      assert html =~ "6 runs planned"
      # All 6 (step × runner) rows are there from the first render — each shows
      # its action — not the ≤5 first-wave runs streaming in one at a time.
      assert html |> String.split("linux.uptime") |> length() == 7
      # The 6th item is beyond the first wave of 5, so it has no run yet and
      # stays a planned placeholder (its dim-zinc ring is unique to :planned).
      assert html =~ "ring-zinc-500/20"
    end

    test "a halted execution says so instead of leaving planned rows grey", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      runner = Emisar.Fixtures.runner_fixture(account_id: account.id)
      Emisar.Fixtures.action_fixture(runner: runner, action_id: "linux.uptime")
      Emisar.Fixtures.policy_fixture(account_id: account.id)
      # 6 steps → 6 runs across 2 waves (batch size 5); wave 2 fires only if
      # the whole first wave succeeds.
      runbook = published_runbook_with_steps!(user, account, runner, 6)

      {:ok, lv, _} = live(conn, ~p"/app/runbooks/#{runbook.id}/run")
      assert render_submit(lv, "dispatch", %{"reason" => "go"}) =~ "6 runs planned"

      # Settle the whole first wave with one failure → the engine refuses to
      # launch wave 2, so its run is never dispatched and its row would sit grey.
      subject = owner_subject(user, account)
      {:ok, runs, _} = Emisar.Runs.list_recent_runs_for_runner(runner.id, subject)
      [failed | rest] = Enum.take(runs, 5)

      {:ok, _} =
        Emisar.Runs.finalize_from_result(failed.runner_id, %{
          "request_id" => failed.request_id,
          "status" => "failed",
          "exit_code" => 1
        })

      for run <- rest do
        {:ok, _} =
          Emisar.Runs.finalize_from_result(run.runner_id, %{
            "request_id" => run.request_id,
            "status" => "success",
            "exit_code" => 0
          })
      end

      html = render(lv)
      assert html =~ "Halted"
      assert html =~ "an earlier step failed"
    end

    test "a partial first-wave dispatch failure marks the failed row, one honest flash", %{
      conn: conn
    } do
      {conn, user, account} = register_and_log_in(conn)
      runner = Emisar.Fixtures.runner_fixture(account_id: account.id)
      Emisar.Fixtures.action_fixture(runner: runner, action_id: "linux.uptime")
      # A second runner that never advertised the action → its slot can't dispatch.
      other = Emisar.Fixtures.runner_fixture(account_id: account.id)
      Emisar.Fixtures.policy_fixture(account_id: account.id)
      subject = owner_subject(user, account)

      {:ok, runbook} =
        Emisar.Runbooks.create_runbook(
          %{
            "title" => "partial",
            "name" => "partial",
            "slug" => "partial",
            "definition" => %{
              "steps" => [
                %{
                  "id" => "ok",
                  "action_id" => "linux.uptime",
                  "args" => %{},
                  "runner_selector" => %{"runner_id" => [runner.id]}
                },
                %{
                  "id" => "bad",
                  "action_id" => "linux.uptime",
                  "args" => %{},
                  "runner_selector" => %{"runner_id" => [other.id]}
                }
              ]
            }
          },
          subject
        )

      {:ok, runbook} = Emisar.Runbooks.publish(runbook, subject)

      {:ok, lv, _} = live(conn, ~p"/app/runbooks/#{runbook.id}/run")
      html = render_submit(lv, "dispatch", %{"reason" => "go"})

      # The failed (step, runner) row is marked instead of staying grey, and the
      # flash is one honest line — not a green "dispatched" beside a red "failed".
      assert html =~ "dispatch failed"
      assert html =~ "failed to dispatch"
    end

    test "a run on an offline runner is flagged on its execution row", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      runner = Emisar.Fixtures.runner_fixture(account_id: account.id, connected?: false)
      Emisar.Fixtures.action_fixture(runner: runner, action_id: "linux.uptime")
      Emisar.Fixtures.policy_fixture(account_id: account.id)
      runbook = published_runbook_targeting!(user, account, runner)

      {:ok, lv, _html} = live(conn, ~p"/app/runbooks/#{runbook.id}/run")

      html = render_submit(lv, "dispatch", %{"reason" => "go"})
      assert html =~ "Runbook dispatched"

      # The created run streams in via {:run_updated}; its runner is offline,
      # so the row flags it — otherwise a stalled wave gives no "why".
      assert render(lv) =~ "offline"
    end

    test "dispatching stays on the page and streams the execution's runs in", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      runner = Emisar.Fixtures.runner_fixture(account_id: account.id)
      Emisar.Fixtures.action_fixture(runner: runner, action_id: "linux.uptime")
      Emisar.Fixtures.policy_fixture(account_id: account.id)
      runbook = published_runbook!(user, account)

      {:ok, lv, idle_html} = live(conn, ~p"/app/runbooks/#{runbook.id}/run")

      # Before dispatch the single table is the plan: heading + step count.
      assert idle_html =~ "Plan"
      assert idle_html =~ "1 step"

      html = render_submit(lv, "dispatch", %{"reason" => "rolling restart"})
      assert html =~ "Runbook dispatched"

      # The engine broadcast the created run before dispatch returned; the
      # next render has processed it into the execution stream — no redirect,
      # the operator watches results arrive on this page. The single table
      # flips its heading from "Plan" to "Execution" and the plan rows are
      # replaced by the live runs.
      html = render(lv)
      assert html =~ "Execution"
      assert html =~ "linux.uptime"
      assert html =~ "on #{runner.name}"
      assert html =~ ~p"/app/runs/"
    end

    test "re-dispatch confirms once an execution is already showing", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      runner = Emisar.Fixtures.runner_fixture(account_id: account.id)
      Emisar.Fixtures.action_fixture(runner: runner, action_id: "linux.uptime")
      Emisar.Fixtures.policy_fixture(account_id: account.id)
      runbook = published_runbook!(user, account)

      {:ok, lv, idle} = live(conn, ~p"/app/runbooks/#{runbook.id}/run")
      # No confirm before any run — a first Start shouldn't nag.
      refute idle =~ "start a new one and replace it"

      html = render_submit(lv, "dispatch", %{"reason" => "go"})
      # An execution is now streaming, so re-Start guards against wiping it.
      assert html =~ "start a new one and replace it"
    end

    test "the plan surfaces each step's action risk before dispatch", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      runner = Emisar.Fixtures.runner_fixture(account_id: account.id)
      # The runbook's lone step is linux.uptime — advertise it as high-risk
      # so the plan must show a high (rose) risk pill, the cue that this step
      # will stop for approval before a fleet-wide dispatch.
      Emisar.Fixtures.action_fixture(runner: runner, action_id: "linux.uptime", risk: "high")
      runbook = published_runbook!(user, account)

      {:ok, _lv, html} = live(conn, ~p"/app/runbooks/#{runbook.id}/run")

      assert html =~ "Plan"
      assert html =~ "linux.uptime"
      assert html =~ "high"
      assert html =~ "ring-rose-500/30"
    end

    test "the plan headline shows the runbook's most-severe step risk", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      runner = Emisar.Fixtures.runner_fixture(account_id: account.id)
      # Two steps at different risks — the headline must show the WORST
      # (critical), not the first or whichever was seen last.
      Emisar.Fixtures.action_fixture(runner: runner, action_id: "linux.uptime", risk: "low")
      Emisar.Fixtures.action_fixture(runner: runner, action_id: "linux.reboot", risk: "critical")
      subject = owner_subject(user, account)

      {:ok, runbook} =
        Emisar.Runbooks.create_runbook(
          %{
            "title" => "mixed risk",
            "name" => "mixed risk",
            "slug" => "mixed-risk",
            "definition" => %{
              "steps" => [
                %{
                  "id" => "read",
                  "action_id" => "linux.uptime",
                  "args" => %{},
                  "runner_selector" => %{"group" => ["default"]}
                },
                %{
                  "id" => "reboot",
                  "action_id" => "linux.reboot",
                  "args" => %{},
                  "runner_selector" => %{"group" => ["default"]}
                }
              ]
            }
          },
          subject
        )

      {:ok, runbook} = Emisar.Runbooks.publish(runbook, subject)

      {:ok, _lv, html} = live(conn, ~p"/app/runbooks/#{runbook.id}/run")

      # The "Plan" heading carries a critical pill — the worst across the steps.
      assert html =~ "Plan"
      assert html =~ "critical"
      assert html =~ "ring-rose-500/40"
    end

    test "a step with no catalog entry shows no risk pill", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      Emisar.Fixtures.runner_fixture(account_id: account.id)
      # No action_fixture for linux.uptime — the catalog hasn't observed it,
      # so the plan step renders without a risk pill (no rose/amber/emerald).
      runbook = published_runbook!(user, account)

      {:ok, _lv, html} = live(conn, ~p"/app/runbooks/#{runbook.id}/run")

      assert html =~ "linux.uptime"
      refute html =~ "ring-rose-500/30"
      refute html =~ "ring-emerald-500/30"
    end

    test "the plan shows each step's own runner target (no run-time picker)", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      _runner = Emisar.Fixtures.runner_fixture(account_id: account.id)
      runbook = published_runbook!(user, account)

      {:ok, _lv, html} = live(conn, ~p"/app/runbooks/#{runbook.id}/run")

      # Targets come from the steps (set in the editor), not a run-time picker —
      # the plan surfaces each step's target. This runbook's lone step targets
      # the "default" group.
      assert html =~ "group: default"
      refute html =~ ~s(name="target")
    end

    test "the idle plan shows the blast radius — runner count per step + run total", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)

      # Two runners in the "default" group the runbook's lone step targets.
      r1 = Emisar.Fixtures.runner_fixture(account_id: account.id, group: "default")
      Emisar.Fixtures.action_fixture(runner: r1, action_id: "linux.uptime")
      r2 = Emisar.Fixtures.runner_fixture(account_id: account.id, group: "default")
      Emisar.Fixtures.action_fixture(runner: r2, action_id: "linux.uptime")
      runbook = published_runbook!(user, account)

      {:ok, _lv, html} = live(conn, ~p"/app/runbooks/#{runbook.id}/run")

      # 1 step × 2 runners = 2 runs in 1 wave; the step shows its own count.
      assert html =~ "2 runs"
      assert html =~ "1 wave"
      assert html =~ "2 runners"
    end

    test "the idle plan warns when a step's group has no active runners", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)

      # A runner exists (so the page loads) but not in the "default" group the
      # step targets — it resolves to zero runners, surfaced before Start.
      Emisar.Fixtures.runner_fixture(account_id: account.id, group: "elsewhere")
      runbook = published_runbook!(user, account)

      {:ok, _lv, html} = live(conn, ~p"/app/runbooks/#{runbook.id}/run")

      assert html =~ "no active runners"
    end

    test "a finished run shows an inline preview of its tail output", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      runner = Emisar.Fixtures.runner_fixture(account_id: account.id)
      Emisar.Fixtures.action_fixture(runner: runner, action_id: "linux.uptime")
      Emisar.Fixtures.policy_fixture(account_id: account.id)
      runbook = published_runbook_targeting!(user, account, runner)

      {:ok, lv, _html} = live(conn, ~p"/app/runbooks/#{runbook.id}/run")
      assert render_submit(lv, "dispatch", %{"reason" => "go"}) =~ "Runbook dispatched"

      # The engine created the run on dispatch — append an output chunk, then
      # finish it. The terminal {:run_updated} broadcast makes the row fetch
      # and show its output tail inline, without leaving the page.
      subject = owner_subject(user, account)
      {:ok, [run], _} = Emisar.Runs.list_recent_runs_for_runner(runner.id, subject)

      {:ok, _} =
        Emisar.Runs.append_event(run, %{
          seq: 1,
          kind: "progress",
          stream: "stdout",
          payload: %{"chunk" => "preview-line\n"}
        })

      {:ok, _} =
        Emisar.Runs.finalize_from_result(run.runner_id, %{
          "request_id" => run.request_id,
          "status" => "success",
          "exit_code" => 0
        })

      assert render(lv) =~ "preview-line"
    end

    test "a refresh rehydrates a live execution instead of resetting to a blank Plan", %{
      conn: conn
    } do
      {conn, user, account} = register_and_log_in(conn)
      runner = Emisar.Fixtures.runner_fixture(account_id: account.id)
      Emisar.Fixtures.action_fixture(runner: runner, action_id: "linux.uptime")
      Emisar.Fixtures.policy_fixture(account_id: account.id)
      runbook = published_runbook_targeting!(user, account, runner)

      # Dispatch — the execution is now in flight (its run is non-terminal).
      {:ok, lv, _html} = live(conn, ~p"/app/runbooks/#{runbook.id}/run")
      assert render_submit(lv, "dispatch", %{"reason" => "go"}) =~ "Runbook dispatched"

      # A fresh mount (the refresh) re-queries the live execution and rebuilds
      # it — heading "Execution" + the run — instead of resetting to "Plan".
      {:ok, _lv2, html} = live(conn, ~p"/app/runbooks/#{runbook.id}/run")
      assert html =~ "Execution"
      assert html =~ "linux.uptime"
      assert html =~ "on #{runner.name}"
    end
  end

  describe "dispatch validation" do
    test "a blank reason shows an inline field error, not a flash", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      Emisar.Fixtures.runner_fixture(account_id: account.id)
      runbook = published_runbook!(user, account)

      {:ok, lv, _html} = live(conn, ~p"/app/runbooks/#{runbook.id}/run")

      # Targets come from the steps now, so the only run-time parameter is the
      # required reason. Dispatching with it blank renders the message inline
      # under the reason field (via <.error>)…
      html = render_submit(lv, "dispatch", %{"reason" => ""})

      assert html =~ "Reason is required"

      # …and never as a flash banner — the flash region carries no error.
      refute html =~ ~s(id="flash-error")
    end

    test "typing a reason clears the inline error live", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      Emisar.Fixtures.runner_fixture(account_id: account.id)
      runbook = published_runbook!(user, account)

      {:ok, lv, _html} = live(conn, ~p"/app/runbooks/#{runbook.id}/run")

      # Trip the inline error first.
      html = render_submit(lv, "dispatch", %{"reason" => ""})
      assert html =~ "Reason is required"

      # Typing a reason clears it live (the field is no longer blank).
      html = render_change(lv, "validate", %{"reason" => "rolling restart"})
      refute html =~ "Reason is required"
    end
  end
end
