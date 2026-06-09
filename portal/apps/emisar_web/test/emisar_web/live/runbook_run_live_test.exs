defmodule EmisarWeb.RunbookRunLiveTest do
  use EmisarWeb.ConnCase, async: true

  defp published_runbook!(user, account) do
    subject = owner_subject(user, account)

    {:ok, rb} =
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

    {:ok, rb} = Emisar.Runbooks.publish(rb, subject)
    rb
  end

  describe "dispatch validation" do
    test "a blank reason shows an inline field error, not a flash", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      Emisar.Fixtures.runner_fixture(account_id: account.id)
      rb = published_runbook!(user, account)

      {:ok, lv, _html} = live(conn, ~p"/app/runbooks/#{rb.id}/run")

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
      rb = published_runbook!(user, account)

      {:ok, lv, _html} = live(conn, ~p"/app/runbooks/#{rb.id}/run")

      # Trip the inline error first.
      html = render_submit(lv, "dispatch", %{"reason" => ""})
      assert html =~ "Reason is required"

      # Typing a reason clears it live (the field is no longer blank).
      html = render_change(lv, "validate", %{"reason" => "rolling restart"})
      refute html =~ "Reason is required"
    end
  end
end
