defmodule Emisar.Accounts.Jobs.MonthlyReports do
  @moduledoc """
  Monthly account-health value report. Once per calendar month it emails each
  active account's Owners a summary of the value emisar delivered in the
  prior month — runs executed, approvals that gated risky work, and current
  posture — rendered by `Emisar.Mailers.MonthlyReport` as text plus HTML.

  Restraint is the product line: inactive accounts, and accounts with no
  meaningful usage in the window, get nothing — an empty "you did nothing"
  report reads like spam.

  Idempotency (IL-13): the work set is derived each tick from
  `accounts.last_report_sent_at` (never sent, or sent in an earlier month), and
  the month is CLAIMED — the stamp written under a row lock, only while the
  account is still due — before the mailer is called, so a repeated or
  concurrent tick can't double-send. A delivery failure after a won claim skips
  that month, which beats a duplicate report to a paying owner.
  """
  use Emisar.Jobs.Job,
    otp_app: :emisar,
    every: :timer.hours(6),
    initial_delay: :timer.minutes(6)

  alias Emisar.{Accounts, Approvals, CalendarMonth, Jobs, Mail, Runners, Runs}
  alias Emisar.Accounts.Account
  require Logger

  @accounts_per_page 100

  @impl Emisar.Jobs.Executors.GloballyUnique
  def execute(config) do
    now = DateTime.utc_now()
    cutoff = CalendarMonth.month_start(now)
    {period_start, period_end} = CalendarMonth.previous_month(now)
    limit = Keyword.get(config, :limit, @accounts_per_page)

    Jobs.Sweep.each_row(
      limit,
      &list_accounts(cutoff, &1, &2),
      &report_account(&1, cutoff, period_start, period_end, limit)
    )
  end

  defp list_accounts(cutoff, limit, cursor),
    do: Accounts.list_accounts_due_for_report(cutoff, limit: limit, after_account_id: cursor)

  # An account that used the email's List-Unsubscribe link gets nothing —
  # stays unstamped so it resumes if it opts back in.
  defp report_account(
         %Account{settings: %{monthly_report_opt_out: true}},
         _cutoff,
         _period_start,
         _period_end,
         _limit
       ),
       do: :ok

  defp report_account(account, cutoff, period_start, period_end, limit) do
    # Check in bounded pages before claiming. No eligible or deliverable Owners
    # leaves the month unstamped; one suppressed address cannot hide the others.
    if deliverable_owner?(account, limit) do
      report = build_report(account, period_start, period_end)

      if reportable?(report),
        do: claim_and_send(account, report, cutoff, limit),
        else: :ok
    end
  end

  defp list_recipients(account, limit, cursor) do
    Accounts.list_account_report_recipients(account, limit: limit, after_membership_id: cursor)
  end

  defp deliverable_owner?(account, limit) do
    Jobs.Sweep.reduce_pages(
      limit,
      false,
      &list_recipients(account, &1, &2),
      fn membership, found? -> found? or not Mail.suppressed?(membership.user.email) end
    )
  end

  # The stamp is the claim, so it is taken first: two ticks that both delivered
  # before stamping would each send the same report, and the loser would only
  # learn it one email too late.
  defp claim_and_send(%Account{} = account, report, cutoff, limit) do
    case Accounts.mark_account_report_sent(account, cutoff) do
      {:ok, claimed_account} ->
        # One account/month claim precedes all delivery. Fresh recipient pages
        # retain current eligibility; a failed delivery is isolated per Owner.
        Jobs.Sweep.each_row(
          limit,
          &list_recipients(claimed_account, &1, &2),
          &send_report(&1.user, claimed_account, report)
        )

      {:error, reason} when reason in [:already_reported, :report_opted_out] ->
        :ok

      {:error, reason} ->
        Logger.warning("account_report.failed", account_id: account.id, error: inspect(reason))
        :ok
    end
  end

  defp send_report(recipient, account, report) do
    case Emisar.Mailers.UserNotifier.deliver_monthly_account_report(recipient, account, report) do
      {:ok, %{suppressed: true}} ->
        :ok

      {:ok, _} ->
        Logger.info("account_report.sent", account_id: account.id)

      {:error, reason} ->
        Logger.warning("account_report.failed", account_id: account.id, error: inspect(reason))
    end
  end

  defp build_report(%Account{} = account, period_start, period_end) do
    %{
      period_start: period_start,
      period_end: period_end,
      runs: Runs.report_run_stats(account.id, period_start, period_end),
      approvals: Approvals.report_request_stats(account.id, period_start, period_end),
      runners: Runners.count_billable_runners(account.id),
      team_size: Accounts.count_memberships(account.id)
    }
  end

  # Meaningful usage in the window: at least one run OR one approval request.
  # Deliberately conservative — no runs and no approvals means no value to
  # report, and we'd rather stay quiet than send a nag.
  defp reportable?(%{runs: %{total: total}, approvals: %{requested: requested}}),
    do: total > 0 or requested > 0
end
