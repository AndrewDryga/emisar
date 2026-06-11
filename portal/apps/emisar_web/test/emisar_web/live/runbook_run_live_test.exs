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

  describe "dispatch + live results" do
    test "dispatching stays on the page and streams the execution's runs in", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      runner = Emisar.Fixtures.runner_fixture(account_id: account.id)
      Emisar.Fixtures.action_fixture(runner: runner, action_id: "linux.uptime")
      Emisar.Fixtures.policy_fixture(account_id: account.id)
      runbook = published_runbook!(user, account)

      {:ok, lv, _html} = live(conn, ~p"/app/runbooks/#{runbook.id}/run")

      html = render_submit(lv, "dispatch", %{"reason" => "rolling restart"})
      assert html =~ "Runbook dispatched"

      # The engine broadcast the created run before dispatch returned; the
      # next render has processed it into the results stream — no redirect,
      # the operator watches results arrive on this page.
      html = render(lv)
      assert html =~ "Results"
      assert html =~ "linux.uptime"
      assert html =~ "on #{runner.name}"
      assert html =~ ~p"/app/runs/"
    end

    test "the target select offers runner groups alongside runners", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      runner = Emisar.Fixtures.runner_fixture(account_id: account.id)
      runbook = published_runbook!(user, account)

      {:ok, _lv, html} = live(conn, ~p"/app/runbooks/#{runbook.id}/run")

      assert html =~ "Runner groups"
      assert html =~ "group:#{runner.group}"
      assert html =~ "runner:#{runner.id}"
    end
  end

  describe "dispatch validation" do
    test "a blank reason shows an inline field error, not a flash", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      Emisar.Fixtures.runner_fixture(account_id: account.id)
      runbook = published_runbook!(user, account)

      {:ok, lv, _html} = live(conn, ~p"/app/runbooks/#{runbook.id}/run")

      # A runner is preselected (mount picks the first), so the only missing run
      # parameter is the required reason. Dispatching with it blank renders the
      # message inline under the reason field (via <.error>)…
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
