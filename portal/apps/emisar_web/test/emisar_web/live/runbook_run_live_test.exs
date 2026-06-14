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
