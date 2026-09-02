defmodule Emisar.Mailers.MonthlyReportTest do
  use ExUnit.Case, async: true
  alias Emisar.Mailers.MonthlyReport
  alias Emisar.Mailers.Style
  alias Emisar.Users

  defp report(overrides \\ %{}) do
    Map.merge(
      %{
        period_start: ~U[2026-07-01 00:00:00Z],
        period_end: ~U[2026-08-01 00:00:00Z],
        runs: %{
          total: 18,
          success: 17,
          failed: 1,
          denied: 0,
          cancelled: 0,
          dispatched: 18,
          distinct_runners: 1
        },
        approvals: %{
          requested: 0,
          approved: 0,
          denied: 0,
          expired: 0,
          cancelled: 0,
          pending: 0,
          waiting_now: 0
        },
        runners: 1,
        team_size: 2
      },
      Map.new(overrides)
    )
  end

  defp render(overrides \\ %{}) do
    recipient = %Users.User{full_name: "Olivia Owner", email: "olivia@example.com"}
    account = %{name: "Fleet Ops", slug: "fleet-ops"}

    MonthlyReport.render(
      recipient,
      account,
      report(overrides),
      "https://emisar.dev/unsubscribe/monthly-report/token"
    )
  end

  describe "render/4" do
    test "names the account and the reported month in the subject" do
      assert render().subject == "Your emisar report for Fleet Ops — July 2026"
    end

    test "both bodies carry the run outcomes, the dashboard link, and the unsubscribe link" do
      rendered = render()

      assert rendered.text =~ "18 runs recorded"
      assert rendered.text =~ "18 dispatched to 1 runner"
      assert rendered.text =~ ~r/Succeeded\s+17$/m
      assert rendered.text =~ ~r/Denied\s+0$/m
      assert rendered.text =~ "/app/fleet-ops"
      assert rendered.text =~ "Unsubscribe: https://emisar.dev/unsubscribe/monthly-report/token"

      assert rendered.html =~ ">18</td>"
      assert rendered.html =~ ">17</td>"
      assert rendered.html =~ ">Denied</td>"
      assert rendered.html =~ ~s(href="#{Emisar.PublicUrl.url("/app/fleet-ops")}")
      assert rendered.html =~ ~s(href="https://emisar.dev/unsubscribe/monthly-report/token")

      assert rendered.html =~
               ~s(style="color:#{Style.brand()};text-decoration:underline;">Unsubscribe</a>)
    end

    test "greets the recipient by email when they have no name" do
      recipient = %Users.User{full_name: nil, email: "nameless@example.com"}
      account = %{name: "Fleet Ops", slug: "fleet-ops"}

      rendered = MonthlyReport.render(recipient, account, report(), "https://emisar.dev/u")

      assert rendered.text =~ "Hi nameless@example.com,"
      assert rendered.html =~ "Hi nameless@example.com,"
    end

    test "reports the approvals that gated work in both bodies" do
      rendered =
        render(%{
          approvals: %{
            requested: 31,
            approved: 27,
            denied: 2,
            expired: 1,
            cancelled: 0,
            pending: 1,
            waiting_now: 3
          }
        })

      assert rendered.text =~ "31 held for a human decision"
      assert rendered.text =~ ~r/Approved\s+27$/m
      assert rendered.text =~ ~r/Approvals waiting\s+3$/m

      assert rendered.html =~ "Approvals"
      assert rendered.html =~ "held for a human decision"
      assert rendered.html =~ ">27</td>"
    end

    test "drops the approvals block from both bodies when nothing was gated" do
      rendered =
        render(%{
          approvals: %{
            requested: 0,
            approved: 0,
            denied: 0,
            expired: 0,
            cancelled: 0,
            pending: 0,
            waiting_now: 0
          }
        })

      refute rendered.text =~ "held for a human decision"
      refute rendered.html =~ "held for a human decision"

      # The waiting queue is posture, not period activity — an empty one still
      # reports, because zero waiting is the reassuring answer.
      assert rendered.text =~ ~r/Approvals waiting\s+0$/m
      assert rendered.html =~ "Approvals waiting"
    end

    test "says runs, not runners, when policy denied every run before dispatch" do
      runs = %{
        total: 4,
        success: 0,
        failed: 0,
        denied: 4,
        cancelled: 0,
        dispatched: 0,
        distinct_runners: 0
      }

      rendered = render(%{runs: runs})

      assert rendered.text =~ "4 runs recorded"
      assert rendered.text =~ "No work was dispatched"
    end

    test "groups thousands so a busy fleet stays readable" do
      runs = %{
        total: 12_018,
        success: 11_902,
        failed: 74,
        denied: 42,
        cancelled: 0,
        dispatched: 11_976,
        distinct_runners: 9
      }

      rendered = render(%{runs: runs})

      assert rendered.text =~ "12,018 runs recorded"
      assert rendered.text =~ "11,976 dispatched across 9 runners"
      assert rendered.html =~ ">12,018</td>"
      assert rendered.html =~ ">11,902</td>"
    end

    test "uses singular run grammar and reports an in-flight remainder" do
      runs = %{
        total: 2,
        success: 1,
        failed: 0,
        denied: 0,
        cancelled: 0,
        dispatched: 1,
        distinct_runners: 1
      }

      rendered = render(%{runs: runs})
      assert rendered.text =~ "2 runs recorded"
      assert rendered.text =~ ~r/In progress\s+1$/m

      one = render(%{runs: %{runs | total: 1}})
      assert one.text =~ "1 run recorded"
      refute one.text =~ "1 runs recorded"
    end

    test "escapes account and recipient names in the HTML body" do
      recipient = %Users.User{full_name: ~s(Olivia "<script>" Owner), email: "olivia@example.com"}
      account = %{name: "<script>alert(1)</script>", slug: "fleet-ops"}

      rendered = MonthlyReport.render(recipient, account, report(), "https://emisar.dev/u")

      refute rendered.html =~ "<script>"
      assert rendered.html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      assert rendered.html =~ "Olivia &quot;&lt;script&gt;&quot; Owner"
    end
  end
end
