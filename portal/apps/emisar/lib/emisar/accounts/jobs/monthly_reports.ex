defmodule Emisar.Accounts.Jobs.MonthlyReports do
  @moduledoc """
  Monthly account-health value report. Once per calendar month it emails each
  active account's stable owner a plain-text summary of the value emisar
  delivered in the prior month — runs executed, approvals that gated risky work,
  and current posture.

  Restraint is the product line: inactive accounts, and accounts with no
  meaningful usage in the window, get nothing — an empty "you did nothing"
  report reads like spam.

  Idempotency (IL-13): the work set is derived each tick from
  `accounts.last_report_sent_at` (never sent, or sent in an earlier month), and
  the stamp is written under a row lock only after the mailer accepts the email
  and only while the account is still due, so a repeated tick can't double-send
  and a delivery failure leaves the timestamp unchanged for the next sweep.
  """
  use Emisar.Jobs.Job,
    otp_app: :emisar,
    every: :timer.hours(6),
    initial_delay: :timer.minutes(6),
    executor: Emisar.Jobs.Executors.GloballyUnique

  alias Emisar.{Accounts, Approvals, CalendarMonth, Mail, Runners, Runs}
  alias Emisar.Accounts.Account
  require Logger

  @accounts_per_page 100

  @impl Emisar.Jobs.Executors.GloballyUnique
  def execute(config) do
    now = DateTime.utc_now()
    cutoff = CalendarMonth.month_start(now)
    {period_start, period_end} = CalendarMonth.previous_month(now)
    limit = Keyword.get(config, :limit, @accounts_per_page)

    sweep_page(limit, cutoff, period_start, period_end, nil)
  end

  defp sweep_page(limit, cutoff, period_start, period_end, after_account_id) do
    accounts =
      Accounts.list_accounts_due_for_report(cutoff,
        limit: limit,
        after_account_id: after_account_id
      )

    Enum.each(accounts, &report_account(&1, cutoff, period_start, period_end))

    if length(accounts) == limit do
      sweep_page(limit, cutoff, period_start, period_end, List.last(accounts).id)
    else
      :ok
    end
  end

  # One bad account or delivery failure is logged and never stops the sweep.
  defp report_account(%Account{} = account, cutoff, period_start, period_end) do
    case Accounts.fetch_account_report_recipient(account) do
      {:ok, recipient} ->
        maybe_send_report(account, recipient, cutoff, period_start, period_end)

      {:error, :no_recipient} ->
        :ok
    end
  rescue
    error ->
      Logger.warning("account_report.crashed",
        account_id: account.id,
        error: inspect(error)
      )

      :ok
  end

  defp maybe_send_report(account, recipient, cutoff, period_start, period_end) do
    # A suppressed (hard-bounced / complained) owner stays unstamped so a future
    # report can still go out if the address recovers.
    if Mail.suppressed?(recipient.email) do
      :ok
    else
      report = build_report(account, period_start, period_end)

      if reportable?(report),
        do: send_and_stamp(account, recipient, report, cutoff),
        else: :ok
    end
  end

  defp send_and_stamp(%Account{} = account, recipient, report, cutoff) do
    with {:ok, _} <-
           Emisar.Mailers.UserNotifier.deliver_monthly_account_report(recipient, account, report),
         {:ok, _} <- Accounts.mark_account_report_sent(account, cutoff) do
      Logger.info("account_report.sent", account_id: account.id)
      :ok
    else
      {:error, :already_reported} ->
        :ok

      {:error, reason} ->
        Logger.warning("account_report.failed", account_id: account.id, error: inspect(reason))
        :ok
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
