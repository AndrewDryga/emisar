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
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      %{conn: conn, user: user, account: account}
    end

    test "the whole plan renders up front as a static list of planned rows", %{
      conn: conn,
      user: user,
      account: account
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime")
      Fixtures.Policies.create_policy(account_id: account.id)
      runbook = published_runbook_with_steps!(user, account, runner, 6)

      {:ok, lv, _} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
      html = render_submit(lv, "dispatch", %{"reason" => "go"})

      assert html =~ "6 runs planned"
      # All 6 (step × runner) rows are there from the first render — each shows
      # its action — not the ≤5 first-wave runs streaming in one at a time.
      assert html |> String.split("linux.uptime") |> length() == 7
      # The 6th item is beyond the first wave of 5, so it has no run yet and
      # stays a planned placeholder — the de-pilled status word at :planned's
      # receded tone (dimmer than routine neutral).
      assert html =~ "text-zinc-500"
      assert html =~ "planned"
    end

    test "a halted execution says so instead of leaving planned rows grey", %{
      conn: conn,
      user: user,
      account: account
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime")
      Fixtures.Policies.create_policy(account_id: account.id)
      # 6 steps → 6 runs across 2 waves (batch size 5); wave 2 fires only if
      # the whole first wave succeeds.
      runbook = published_runbook_with_steps!(user, account, runner, 6)

      {:ok, lv, _} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
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
      assert html =~ "An earlier step failed"
    end

    test "a partial first-wave dispatch failure marks the failed row, one honest flash", %{
      conn: conn,
      user: user,
      account: account
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime")
      # A second runner that never advertised the action → its slot can't dispatch.
      other = Fixtures.Runners.create_runner(account_id: account.id)
      Fixtures.Policies.create_policy(account_id: account.id)
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

      {:ok, lv, _} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
      html = render_submit(lv, "dispatch", %{"reason" => "go"})

      # The failed (step, runner) row is marked instead of staying grey, and the
      # flash is one honest line — not a green "dispatched" beside a red "failed".
      assert html =~ "dispatch failed"
      assert html =~ "failed to dispatch"
    end

    test "a run on an offline runner is flagged on its execution row", %{
      conn: conn,
      user: user,
      account: account
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime")
      Fixtures.Policies.create_policy(account_id: account.id)
      runbook = published_runbook_targeting!(user, account, runner)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")

      html = render_submit(lv, "dispatch", %{"reason" => "go"})
      assert html =~ "Runbook dispatched"

      # The created run streams in via {:run_updated}; its runner is offline,
      # so the row flags it — otherwise a stalled wave gives no "why".
      assert render(lv) =~ "offline"
    end

    test "dispatching stays on the page and streams the execution's runs in", %{
      conn: conn,
      user: user,
      account: account
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime")
      Fixtures.Policies.create_policy(account_id: account.id)
      runbook = published_runbook!(user, account)

      {:ok, lv, idle_html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")

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
      assert html =~ ~p"/app/#{account}/runs/"
    end

    test "the dispatch form is hidden while a run is in progress (no double-dispatch mid-run)",
         %{conn: conn, user: user, account: account} do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime")
      Fixtures.Policies.create_policy(account_id: account.id)
      runbook = published_runbook!(user, account)

      {:ok, lv, idle} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
      # Idle: the dispatch form is shown, and a first Start doesn't nag with a confirm.
      assert idle =~ "Run runbook"
      refute idle =~ "start a new one and replace it"

      # Once dispatched, a run is in progress → the form is hidden so a stray
      # submit can't double-dispatch mid-run; a "running" note stands in its place.
      # (It returns as the re-run form — with the replace-confirm — once runs settle.)
      html = render_submit(lv, "dispatch", %{"reason" => "go"})
      assert html =~ "Runbook is running"
      refute html =~ "Run runbook"
    end

    test "the plan surfaces each step's action risk before dispatch", %{
      conn: conn,
      user: user,
      account: account
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      # The runbook's lone step is linux.uptime — advertise it as high-risk
      # so the plan must show a high (rose) risk pill, the cue that this step
      # will stop for approval before a fleet-wide dispatch.
      Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "high")
      runbook = published_runbook!(user, account)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")

      assert html =~ "Plan"
      assert html =~ "linux.uptime"
      assert html =~ "high"
      assert html =~ "ring-rose-500/30"
    end

    test "the plan headline shows the runbook's most-severe step risk", %{
      conn: conn,
      user: user,
      account: account
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      # Two steps at different risks — the headline must show the WORST
      # (critical), not the first or whichever was seen last.
      Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      Fixtures.Catalog.create_action(runner: runner, action_id: "linux.reboot", risk: "critical")
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

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")

      # The "Plan" heading carries a critical pill — the worst across the steps.
      assert html =~ "Plan"
      assert html =~ "critical"
      assert html =~ "ring-rose-500/40"
    end

    test "the plan marks a step that will pause for approval, but not an allowed one", %{
      conn: conn,
      user: user,
      account: account
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "default")
      # The account's default policy (seeded on creation) gates high → approval,
      # low → allow. Advertise one low and one high action so the plan marks the
      # high step "Pauses for approval" and leaves the low one unmarked.
      Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime", risk: "low")
      Fixtures.Catalog.create_action(runner: runner, action_id: "linux.reboot", risk: "high")
      subject = owner_subject(user, account)

      {:ok, runbook} =
        Emisar.Runbooks.create_runbook(
          %{
            "title" => "approval mix",
            "name" => "approval mix",
            "slug" => "approval-mix",
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

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")

      # The high-risk reboot step is marked; exactly one step carries the marker
      # (the low-risk uptime step runs straight through, so it stays unmarked).
      assert html =~ "Pauses for approval"
      assert html |> String.split("Pauses for approval") |> length() == 2
    end

    test "a step with no catalog entry shows no risk pill", %{
      conn: conn,
      user: user,
      account: account
    } do
      Fixtures.Runners.create_runner(account_id: account.id)
      # No Fixtures.Catalog.create_action for linux.uptime — the catalog hasn't observed it,
      # so the plan step renders without a risk pill (no rose/amber/emerald).
      runbook = published_runbook!(user, account)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")

      assert html =~ "linux.uptime"
      refute html =~ "ring-rose-500/30"
      refute html =~ "ring-brand-500/30"
    end

    test "the plan shows each step's own runner target (no run-time picker)", %{
      conn: conn,
      user: user,
      account: account
    } do
      _runner = Fixtures.Runners.create_runner(account_id: account.id)
      runbook = published_runbook!(user, account)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")

      # Targets come from the steps (set in the editor), not a run-time picker —
      # the plan surfaces each step's target. This runbook's lone step targets
      # the "default" group.
      assert html =~ "group: default"
      refute html =~ ~s(name="target")
    end

    test "the idle plan shows the blast radius — runner count per step + run total", %{
      conn: conn,
      user: user,
      account: account
    } do
      # Two runners in the "default" group the runbook's lone step targets.
      r1 = Fixtures.Runners.create_runner(account_id: account.id, group: "default")
      Fixtures.Catalog.create_action(runner: r1, action_id: "linux.uptime")
      r2 = Fixtures.Runners.create_runner(account_id: account.id, group: "default")
      Fixtures.Catalog.create_action(runner: r2, action_id: "linux.uptime")
      runbook = published_runbook!(user, account)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")

      # 1 step × 2 runners = 2 runs in 1 wave; the step shows its own count.
      assert html =~ "2 runs"
      assert html =~ "1 wave"
      assert html =~ "2 runners"
    end

    test "the idle plan warns when a step's group has no active runners", %{
      conn: conn,
      user: user,
      account: account
    } do
      # A runner exists (so the page loads) but not in the "default" group the
      # step targets — it resolves to zero runners, surfaced before Start.
      Fixtures.Runners.create_runner(account_id: account.id, group: "elsewhere")
      runbook = published_runbook!(user, account)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")

      assert html =~ "no active runners"
    end

    test "a finished run shows an inline preview of its tail output", %{
      conn: conn,
      user: user,
      account: account
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime")
      Fixtures.Policies.create_policy(account_id: account.id)
      runbook = published_runbook_targeting!(user, account, runner)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
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
      conn: conn,
      user: user,
      account: account
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime")
      Fixtures.Policies.create_policy(account_id: account.id)
      runbook = published_runbook_targeting!(user, account, runner)

      # Dispatch — the execution is now in flight (its run is non-terminal).
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
      assert render_submit(lv, "dispatch", %{"reason" => "go"}) =~ "Runbook dispatched"

      # A fresh mount (the refresh) re-queries the live execution and rebuilds
      # it — heading "Execution" + the run — instead of resetting to "Plan".
      {:ok, _lv2, html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
      assert html =~ "Execution"
      assert html =~ "linux.uptime"
      assert html =~ "on #{runner.name}"
    end

    test "a refresh keeps dispatched runs in step order, not shoved below the planned rows", %{
      conn: conn,
      user: user,
      account: account
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime")
      Fixtures.Policies.create_policy(account_id: account.id)
      # 7 steps, 1 runner → wave 1 dispatches steps 1-5; steps 6-7 stay planned.
      runbook = published_runbook_with_steps!(user, account, runner, 7)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
      assert render_submit(lv, "dispatch", %{"reason" => "go"}) =~ "Runbook dispatched"

      # The refresh rehydrates from the DB. A dispatched run (step 1) must render
      # ABOVE a still-planned placeholder (step 6) — the old rehydrate streamed
      # the placeholders then re-inserted the runs, shoving every dispatched run
      # to the end of the list and scrambling the step order.
      {:ok, _lv2, html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")

      {step1_at, _} = :binary.match(html, "run-step1-")
      {step6_at, _} = :binary.match(html, "run-step6-")
      assert step1_at < step6_at
    end
  end

  describe "preflight plan (RBK-007)" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      %{conn: conn, user: user, account: account}
    end

    test "a runner_id-targeted step resolves its runner ids to names in the plan", %{
      conn: conn,
      user: user,
      account: account
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id, name: "edge-eu-1")
      Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime")
      runbook = published_runbook_targeting!(user, account, runner)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")

      # The step targets the runner by id; the plan must resolve that id to the
      # runner's NAME (step_target_label/2), not echo the raw uuid.
      assert html =~ "edge-eu-1"
      refute html =~ runner.id
    end

    test "the idle plan warns that an offline target will queue until it reconnects", %{
      conn: conn,
      user: user,
      account: account
    } do
      # An offline runner targeted by id stays in the plan (a runner-id selector
      # passes offline members through; a group selector would skip them). Before
      # Start, the plan flags that its steps will QUEUE — a heads-up, not a blocker.
      runner =
        Fixtures.Runners.create_runner(account_id: account.id, name: "sleepy", connected?: false)

      Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime")
      runbook = published_runbook_targeting!(user, account, runner)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")

      assert html =~ "sleepy"
      assert html =~ "queues their steps until they reconnect"
    end

    test "a fan-out beyond the cap is refused with a humanized flash, not a raw atom", %{
      conn: conn,
      user: user,
      account: account
    } do
      # (LV half)
      subject = owner_subject(user, account)

      # 21 steps × 50 runner-ids = 1050 resolved runs, over the 1000 cap. Each step
      # is under the per-step selector cap (50), so the runbook publishes; the cap
      # trips while resolving the materialized fan-out. Dispatch must surface the
      # humanized sentence (format_reason/1), not the raw {:fan_out_too_large, …}.
      steps =
        for n <- 1..21 do
          %{
            "id" => "step#{n}",
            "action_id" => "linux.uptime",
            "args" => %{},
            "runner_selector" => %{"runner_id" => Enum.map(1..50, &"r#{n}_#{&1}")}
          }
        end

      {:ok, runbook} =
        Emisar.Runbooks.create_runbook(
          %{
            "title" => "fan out",
            "name" => "fan out",
            "slug" => "fan-out",
            "definition" => %{"steps" => steps}
          },
          subject
        )

      {:ok, runbook} = Emisar.Runbooks.publish(runbook, subject)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
      html = render_submit(lv, "dispatch", %{"reason" => "go"})

      assert html =~ "fan out to more than 1000 runs"
      refute html =~ "fan_out_too_large"
    end

    test "a stepless runbook shows the empty-state nudge to the editor, not a dispatch", %{
      conn: conn,
      user: user,
      account: account
    } do
      subject = owner_subject(user, account)

      # Publish enforces ≥1 step, so a stepless runbook is a draft (the run screen
      # fetches drafts too). Its plan must rest on the "No steps defined" nudge
      # rather than offering an empty dispatch.
      {:ok, runbook} =
        Emisar.Runbooks.create_runbook(
          %{
            "title" => "empty",
            "name" => "empty",
            "slug" => "empty",
            "definition" => %{"steps" => []}
          },
          subject
        )

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")

      assert html =~ "No steps defined"
      assert html =~ ~p"/app/#{account}/runbooks/#{runbook.id}/edit"
    end
  end

  describe "live progress (RBK-010)" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      %{conn: conn, user: user, account: account}
    end

    test "the header shows finished/total and the failed count as runs settle", %{
      conn: conn,
      user: user,
      account: account
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime")
      Fixtures.Policies.create_policy(account_id: account.id)
      # 3 steps × 1 runner = 3 runs in one wave — finishing one as failed shows
      # both the finished/total tally and the failed count in the header.
      runbook = published_runbook_with_steps!(user, account, runner, 3)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
      assert render_submit(lv, "dispatch", %{"reason" => "go"}) =~ "3 runs planned"

      subject = owner_subject(user, account)
      {:ok, runs, _} = Emisar.Runs.list_recent_runs_for_runner(runner.id, subject)
      [failed | _] = runs

      {:ok, _} =
        Emisar.Runs.finalize_from_result(failed.runner_id, %{
          "request_id" => failed.request_id,
          "status" => "failed",
          "exit_code" => 1
        })

      html = render(lv)
      # One of three has settled, and it failed — the header carries both counts.
      assert html =~ "1/3 finished"
      assert html =~ "1 failed"
    end

    test "a run_updated for a DIFFERENT execution is ignored", %{
      conn: conn,
      user: user,
      account: account
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime")
      Fixtures.Policies.create_policy(account_id: account.id)
      runbook = published_runbook_targeting!(user, account, runner)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
      assert render_submit(lv, "dispatch", %{"reason" => "go"}) =~ "Runbook dispatched"

      subject = owner_subject(user, account)
      {:ok, [run], _} = Emisar.Runs.list_recent_runs_for_runner(runner.id, subject)

      # A run carrying a foreign execution id (and a DISTINCT step id so a wrongly
      # streamed row would be a new, detectable dom_id) arrives on the account
      # topic. The page is keyed to its OWN execution, so it must drop this one —
      # no `run-other_step-…` row appears.
      foreign = %{
        run
        | runbook_execution_id: Emisar.Repo.generate_id(),
          runbook_step_id: "other_step"
      }

      send(lv.pid, {:run_updated, foreign})

      refute render(lv) =~ "run-other_step-"
      # The original execution row is still the only run row on the page.
      assert render(lv) =~ "Execution"
    end

    test "an unrelated forwarded broadcast is swallowed by the catch-all", %{
      conn: conn,
      user: user,
      account: account
    } do
      Fixtures.Runners.create_runner(account_id: account.id)
      runbook = published_runbook!(user, account)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")

      # The shared badge/fleet hooks forward account-topic messages to every LV;
      # this page's handle_info catch-all must swallow ones it doesn't render
      # (mandatory per the LiveView memory) without crashing the process.
      send(lv.pid, {:list_changed, :approval, "approval.created", "irrelevant"})
      send(lv.pid, :some_unrelated_message)

      assert render(lv) =~ "Plan"
    end

    test "on refresh, a dispatched run whose plan slot no longer resolves is appended, not dropped",
         %{conn: conn, user: user, account: account} do
      subject = owner_subject(user, account)

      # published_runbook!'s lone step targets group "default". Dispatch fans it to
      # the one active member (runner_b); the run is created against runner_b.
      runner_b =
        Fixtures.Runners.create_runner(account_id: account.id, group: "default", name: "node-b")

      Fixtures.Catalog.create_action(runner: runner_b, action_id: "linux.uptime")
      Fixtures.Policies.create_policy(account_id: account.id)
      runbook = published_runbook!(user, account)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
      assert render_submit(lv, "dispatch", %{"reason" => "go"}) =~ "Runbook dispatched"

      {:ok, [run_b], _} = Emisar.Runs.list_recent_runs_for_runner(runner_b.id, subject)

      # The group's membership changes AFTER dispatch: runner_b is disabled and a
      # fresh active member joins. On refresh, resolve_plan re-resolves the step to
      # the NEW runner (node-c), so runner_b's already-dispatched run no longer
      # matches a plan slot. merged_execution_rows must APPEND it (in dispatch
      # order) rather than silently drop a run the operator already saw.
      {:ok, _} = Emisar.Runners.disable_runner(runner_b, subject)

      runner_c =
        Fixtures.Runners.create_runner(account_id: account.id, group: "default", name: "node-c")

      Fixtures.Catalog.create_action(runner: runner_c, action_id: "linux.uptime")

      {:ok, _lv2, html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")

      # The execution rehydrates and runner_b's orphaned run still renders…
      assert html =~ "Execution"
      assert html =~ "run-uptime-#{run_b.runner_id}"
      assert html =~ "on node-b"
      # …alongside the re-resolved placeholder slot for the new group member.
      assert html =~ "run-uptime-#{runner_c.id}"
    end

    test "markup in a run's output is escaped, never rendered as raw HTML", %{
      conn: conn,
      user: user,
      account: account
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime")
      Fixtures.Policies.create_policy(account_id: account.id)
      runbook = published_runbook_targeting!(user, account, runner)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
      assert render_submit(lv, "dispatch", %{"reason" => "go"}) =~ "Runbook dispatched"

      # The runner output is attacker-influenced — emit a <script> tag, then
      # finish the run so its tail preview renders. It must go through
      # output_preview (HEEx-escaped), never raw/1 (IL-16): the page shows the
      # escaped text, not an executable tag.
      subject = owner_subject(user, account)
      {:ok, [run], _} = Emisar.Runs.list_recent_runs_for_runner(runner.id, subject)

      {:ok, _} =
        Emisar.Runs.append_event(run, %{
          seq: 1,
          kind: "progress",
          stream: "stdout",
          payload: %{"chunk" => "<script>alert('xss')</script>\n"}
        })

      {:ok, _} =
        Emisar.Runs.finalize_from_result(run.runner_id, %{
          "request_id" => run.request_id,
          "status" => "success",
          "exit_code" => 0
        })

      html = render(lv)
      assert html =~ "&lt;script&gt;"
      refute html =~ "<script>alert"
    end
  end

  describe "dispatch validation" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      %{conn: conn, user: user, account: account}
    end

    test "a blank reason shows an inline field error, not a flash", %{
      conn: conn,
      user: user,
      account: account
    } do
      Fixtures.Runners.create_runner(account_id: account.id)
      runbook = published_runbook!(user, account)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")

      # Targets come from the steps now, so the only run-time parameter is the
      # required reason. Dispatching with it blank renders the message inline
      # under the reason field (via <.error>)…
      html = render_submit(lv, "dispatch", %{"reason" => ""})

      assert html =~ "Reason is required"

      # …and never as a flash banner — the flash region carries no error.
      refute html =~ ~s(id="flash-error")
    end

    test "typing a reason clears the inline error live", %{
      conn: conn,
      user: user,
      account: account
    } do
      Fixtures.Runners.create_runner(account_id: account.id)
      runbook = published_runbook!(user, account)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")

      # Trip the inline error first.
      html = render_submit(lv, "dispatch", %{"reason" => ""})
      assert html =~ "Reason is required"

      # Typing a reason clears it live (the field is no longer blank).
      html = render_change(lv, "validate", %{"reason" => "rolling restart"})
      refute html =~ "Reason is required"
    end
  end
end
