defmodule Emisar.Mailers.TextLayoutTest do
  @moduledoc """
  The plain-text layout contract every transactional email shares: **a paragraph
  is one line.** A mail client re-wraps a long line to the window it has, but it
  can never undo a newline we sent — so a paragraph wrapped in the source breaks
  at a column nobody chose.

  Interpolation is what makes it unfixable by eye: the invitation's opening line
  read `Andrew Dryga invited you to join the` and broke there, 36 characters in,
  because the rendered inviter name is a third of the width of the
  `\#{inviter.full_name || inviter.email}` placeholder the author wrapped around.

  A source-wrapped paragraph always leaves a line that stops mid-sentence, starts
  mid-sentence, or both — which is what this file looks for, over every body we
  actually send. A new email belongs in `bodies/0`; the contract only covers what
  it renders.
  """
  use Emisar.DataCase, async: true
  alias Emisar.Fixtures
  alias Emisar.Mailers.MonthlyReport
  alias Emisar.Mailers.UserNotifier
  alias Emisar.RequestContext
  alias Emisar.Runs

  describe "every transactional email" do
    test "keeps each paragraph on one line" do
      Enum.each(bodies(), fn {email, body} ->
        lines = prose_lines(body)

        assert lines != [], "#{email}: rendered no prose at all"

        Enum.each(lines, fn line ->
          assert line =~ ~r/[.:!?,—]$/,
                 "#{email}: a paragraph is wrapped in the source — this line stops " <>
                   "mid-sentence: #{inspect(line)}"

          assert starts_a_sentence?(line),
                 "#{email}: a paragraph is wrapped in the source — this line starts " <>
                   "mid-sentence: #{inspect(line)}"
        end)
      end)
    end
  end

  # Structure sets its own measure and is not prose: the blank line between
  # blocks, an indented code or `Label:` block, an ALL-CAPS section eyebrow, a
  # line carrying a URL. What remains is a sentence.
  defp prose_lines(body) do
    body
    |> String.split("\n")
    |> Enum.reject(fn line ->
      line == "" or String.starts_with?(line, " ") or line =~ ~r{https?://} or
        String.upcase(line) == line
    end)
  end

  # Our own brand name is the one word that opens a sentence in lower case.
  defp starts_a_sentence?("emisar" <> _rest), do: true

  defp starts_a_sentence?(line) do
    first = String.first(line)
    String.upcase(first) == first
  end

  defp bodies do
    user = Fixtures.Users.create_user(full_name: "Andrew Dryga")
    account = Fixtures.Accounts.create_account(name: "Fleet Ops")

    UserNotifier.deliver_account_confirmation(user, "tok-confirm", account, request_context())
    confirmation = sent_text_body()

    UserNotifier.deliver_email_change_confirmation(
      user,
      "tok-new-email",
      account,
      request_context()
    )

    email_change_confirmation = sent_text_body()

    UserNotifier.deliver_magic_link(user, "tok", "ABC234", request_context(), nil, account)
    magic_link = sent_text_body()

    UserNotifier.deliver_email_change_code(
      user,
      "ABC234",
      "new@example.com",
      request_context(),
      account
    )

    email_change = sent_text_body()

    UserNotifier.deliver_mfa_enrollment_code(user, "ABC234", request_context(), account)
    mfa_enrollment = sent_text_body()

    UserNotifier.deliver_oidc_identity_step_up_code(
      user,
      "123456",
      "Okta Workforce",
      :link,
      request_context(),
      account
    )

    oidc_identity_step_up = sent_text_body()

    invitation_membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

    UserNotifier.deliver_account_invitation(
      user,
      user,
      account,
      invitation_membership,
      "tok-invite"
    )

    invitation = sent_text_body()

    [
      {"confirmation", confirmation},
      {"email change confirmation", email_change_confirmation},
      {"magic link", magic_link},
      {"email change code", email_change},
      {"authenticator code", mfa_enrollment},
      {"OIDC identity step-up", oidc_identity_step_up},
      {"invitation", invitation},
      {"approval request", approval_request_body(user, account)},
      {"runbook approval request", runbook_approval_request_body(user, account)},
      {"approval decision", approval_decision_body(user, account)},
      {"approval update", approval_event_body(user, account)},
      {"monthly report", monthly_report_text(user, account)}
    ]
  end

  defp approval_request_body(user, account) do
    membership = Fixtures.Memberships.fetch_membership(account.id, user.id)

    subject = Fixtures.Subjects.membership_subject(membership)
    runner = Fixtures.Runners.create_runner(account_id: account.id, name: "edge-1")

    persisted =
      Fixtures.Runs.create_run(
        account_id: account.id,
        runner_id: runner.id,
        action_id: "caddy.reload_config",
        args_raw: ~s({"path":"/etc/caddy","token":"secret-value"}),
        sensitive_arg_names: ["token"]
      )

    {:ok, run} = Runs.fetch_run_by_id(persisted.id, subject, preload: [:runner])

    request = %{
      id: "req-id-123",
      reason: "rotate the expiring edge certificate",
      matched_rules: ["high → approve"],
      account: account
    }

    UserNotifier.deliver_approval_request(subject, request, run)
    sent_text_body()
  end

  defp runbook_approval_request_body(user, account) do
    request = %{
      id: "req-execution-1",
      reason: "apply the reviewed settings",
      account: account,
      context: %{
        "execution_id" => "exec-123",
        "runbook" => %{"title" => "Database maintenance"},
        "plan" => %{
          "total_items" => 1,
          "stages" => [
            %{
              "id" => "apply",
              "title" => "Apply database change",
              "items" => [
                %{
                  "action" => "postgres.config_validate",
                  "runner_ref" => "db-01",
                  "pack_ref" => "postgres@1.4.2/sha256:" <> String.duplicate("a", 64),
                  "risk" => "medium",
                  "args" => %{"token" => "[REDACTED]"}
                }
              ]
            }
          ]
        }
      }
    }

    membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
    subject = Fixtures.Subjects.membership_subject(membership)
    UserNotifier.deliver_runbook_execution_approval_request(subject, request)
    sent_text_body()
  end

  defp approval_decision_body(user, account) do
    request = %{
      id: "req-decided-1",
      status: :approved,
      reason: "rotate the expiring edge certificate",
      decision_reason: "confirmed with the on-call",
      account: account,
      context: %{"action_id" => "caddy.reload_config"}
    }

    UserNotifier.deliver_approval_decision(user, request)
    sent_text_body()
  end

  defp approval_event_body(user, account) do
    membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
    subject = Fixtures.Subjects.membership_subject(membership)

    request = %{
      id: "req-event-1",
      min_approvals: 2,
      account: account,
      context: %{"action_id" => "caddy.reload_config"}
    }

    UserNotifier.deliver_approval_event(subject, request, %{
      id: "decision-1",
      kind: :vote,
      approved_count: 1,
      actor_label: "Avery Operator",
      occurred_at: ~U[2026-08-25 12:30:00Z],
      reason: "Reviewed with the on-call"
    })

    sent_text_body()
  end

  defp monthly_report_text(user, account) do
    report = %{
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
        requested: 4,
        approved: 3,
        denied: 1,
        expired: 0,
        cancelled: 0,
        pending: 0,
        waiting_now: 1
      },
      runners: 1,
      team_size: 2
    }

    MonthlyReport.render(user, account, report, "http://localhost/unsubscribe/token").text
  end

  defp request_context do
    %RequestContext{
      ip_address: "203.0.113.7",
      user_agent:
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " <>
          "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36"
    }
  end

  defp sent_text_body do
    assert_received {:email, email}
    email.text_body
  end
end
