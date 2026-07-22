defmodule Emisar.Accounts.Jobs.MonthlyReportsTest do
  use Emisar.DataCase, async: true
  alias Emisar.Accounts.Jobs.MonthlyReports
  alias Emisar.{CalendarMonth, Mail, Repo}
  alias Emisar.Fixtures

  # A confirmed owner + one successful run inside the prior-month window — the
  # minimum an account needs to earn a report.
  defp active_account(opts \\ []) do
    account = Fixtures.Accounts.create_account()

    owner =
      Fixtures.Users.create_user(
        full_name: Keyword.get(opts, :owner_name, "Olivia Owner"),
        email: Keyword.get(opts, :owner_email, Fixtures.Random.unique_email())
      )

    Fixtures.Memberships.create_membership(
      account_id: account.id,
      user_id: owner.id,
      role: "owner"
    )

    for _ <- 1..Keyword.get(opts, :runs, 1) do
      Fixtures.Runs.create_run(
        account_id: account.id,
        status: :success,
        inserted_at: in_window()
      )
    end

    %{account: account, owner: owner}
  end

  defp in_window do
    {period_start, _period_end} = CalendarMonth.previous_month(DateTime.utc_now())
    DateTime.add(period_start, 3600, :second)
  end

  describe "execute/1" do
    test "emails the owner the prior month's summary and stamps the account" do
      %{account: account, owner: owner} = active_account(runs: 3)

      assert :ok = MonthlyReports.execute([])

      {period_start, _period_end} = CalendarMonth.previous_month(DateTime.utc_now())
      period = Calendar.strftime(period_start, "%B %Y")

      assert_received {:email, email}
      assert email.to == [{"", owner.email}]
      assert email.subject == "Your emisar report for #{account.name} — #{period}"
      assert email.reply_to == {"", "support@emisar.dev"}
      assert email.text_body =~ "Total:     3"
      assert email.text_body =~ "Succeeded: 3"
      assert email.text_body =~ "Active runners:"
      assert email.text_body =~ "/app/#{account.slug}"
      assert email.text_body =~ "Unsubscribe: "
      assert email.headers["List-Unsubscribe"] =~ "/unsubscribe/monthly-report/"
      assert email.headers["List-Unsubscribe-Post"] == "List-Unsubscribe=One-Click"

      assert Repo.reload(account).last_report_sent_at
    end

    test "a fresh timestamp makes a repeated execute a no-op" do
      %{account: account} = active_account()

      assert :ok = MonthlyReports.execute([])
      assert_received {:email, _first}
      first_stamp = Repo.reload(account).last_report_sent_at

      assert :ok = MonthlyReports.execute([])
      refute_received {:email, _second}
      assert Repo.reload(account).last_report_sent_at == first_stamp
    end

    test "an account with no usage in the window receives nothing" do
      account = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

      assert :ok = MonthlyReports.execute([])

      refute_received {:email, _}
      refute Repo.reload(account).last_report_sent_at
    end

    test "an account with no confirmed owner receives nothing" do
      account = Fixtures.Accounts.create_account()
      unconfirmed = Fixtures.Users.create_user(confirmed?: false)

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: unconfirmed.id,
        role: "owner"
      )

      Fixtures.Runs.create_run(account_id: account.id, status: :success, inserted_at: in_window())

      assert :ok = MonthlyReports.execute([])

      refute_received {:email, _}
      refute Repo.reload(account).last_report_sent_at
    end

    test "a suppressed owner address receives nothing and stays unstamped" do
      %{account: account, owner: owner} = active_account()
      {:ok, _} = Mail.suppress(owner.email, :hard_bounce, "HardBounce")

      assert :ok = MonthlyReports.execute([])

      refute_received {:email, _}
      refute Repo.reload(account).last_report_sent_at
    end

    test "an account opted out of reports receives nothing and stays unstamped" do
      %{account: account} = active_account()
      Fixtures.Accounts.set_account_settings(account, %{monthly_report_opt_out: true})

      assert :ok = MonthlyReports.execute([])

      refute_received {:email, _}
      refute Repo.reload(account).last_report_sent_at
    end

    test "a delivery failure leaves last_report_sent_at unchanged for the next sweep" do
      %{account: account} = active_account()

      Emisar.Config.put_override(:emisar, :mailer_deliver_error, {:error, {:failed, :boom}})

      assert :ok = MonthlyReports.execute([])

      refute Repo.reload(account).last_report_sent_at
    end

    test "each account's report carries only its own numbers (cross-account isolation)" do
      %{account: account_a, owner: owner_a} = active_account(runs: 2)
      %{account: account_b, owner: owner_b} = active_account(runs: 5)

      assert :ok = MonthlyReports.execute([])

      emails =
        for _ <- 1..2 do
          assert_receive {:email, email}
          email
        end

      by_address = Map.new(emails, fn email -> {email.to |> hd() |> elem(1), email} end)

      assert by_address[owner_a.email].text_body =~ "Total:     2"
      assert by_address[owner_a.email].text_body =~ "/app/#{account_a.slug}"
      assert by_address[owner_b.email].text_body =~ "Total:     5"
      assert by_address[owner_b.email].text_body =~ "/app/#{account_b.slug}"
    end
  end
end
