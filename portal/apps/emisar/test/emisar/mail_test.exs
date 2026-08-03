defmodule Emisar.MailTest do
  @moduledoc """
  The email-suppression store: addresses that hard-bounced or complained
  are recorded (from the Postmark webhook) and the transactional mailer
  skips them on its next send.
  """
  use Emisar.DataCase, async: true
  import Swoosh.TestAssertions
  alias Emisar.Fixtures
  alias Emisar.Mail
  alias Emisar.Mailers.UserNotifier
  alias Emisar.RequestContext
  alias Emisar.Runs

  describe "suppressed?/1" do
    test "reports a suppressed address case-insensitively (citext key)" do
      {:ok, _} = Mail.suppress("Bounced@Example.com", :hard_bounce, "HardBounce")

      assert Mail.suppressed?("bounced@example.com")
      assert Mail.suppressed?("BOUNCED@EXAMPLE.COM")
      refute Mail.suppressed?("someone-else@example.com")
    end

    test "trims the input before the lookup" do
      {:ok, _} = Mail.suppress("trim@example.com", :hard_bounce, "bounce")

      assert Mail.suppressed?("  trim@example.com  ")
    end

    test "is false for a non-binary (the guard's fallback clause)" do
      refute Mail.suppressed?(nil)
    end
  end

  describe "suppressed_emails/1" do
    test "returns the suppressed subset, keyed to the caller's strings" do
      {:ok, _} = Mail.suppress("bounced@example.com", :hard_bounce, "bounce")
      {:ok, _} = Mail.suppress("complained@example.com", :spam_complaint, "complaint")

      result =
        Mail.suppressed_emails([
          "Bounced@Example.com",
          "complained@example.com",
          "fine@example.com"
        ])

      assert result == MapSet.new(["Bounced@Example.com", "complained@example.com"])
    end

    test "is empty for an empty list" do
      assert Mail.suppressed_emails([]) == MapSet.new()
    end

    test "drops nil/blank entries (SSO members have no email)" do
      {:ok, _} = Mail.suppress("bounced@example.com", :hard_bounce, "bounce")

      assert Mail.suppressed_emails([nil, nil]) == MapSet.new()

      result = Mail.suppressed_emails([nil, "bounced@example.com", "  ", "fine@example.com"])
      assert result == MapSet.new(["bounced@example.com"])
    end
  end

  describe "handle_deliverability_event/1" do
    test "a deactivating bounce is suppressed as a hard bounce, with the reported detail" do
      {:ok, event} =
        Mail.DeliverabilityEvent.new(:bounce, %{
          email: "dead@example.com",
          inactive: true,
          type: "HardBounce",
          description: "no such mailbox"
        })

      assert Mail.handle_deliverability_event(event) == {:ok, :suppressed}

      suppression = Repo.one(Mail.Suppression)
      assert suppression.email == "dead@example.com"
      assert suppression.reason == :hard_bounce
      assert suppression.detail == "HardBounce: no such mailbox"
    end

    test "a spam complaint is suppressed as a complaint" do
      {:ok, event} = Mail.DeliverabilityEvent.new(:spam_complaint, %{email: "angry@example.com"})

      assert Mail.handle_deliverability_event(event) == {:ok, :suppressed}

      suppression = Repo.one(Mail.Suppression)
      assert suppression.reason == :spam_complaint
      assert is_nil(suppression.detail)
    end

    test "a transient bounce is ignored and stores nothing" do
      {:ok, event} =
        Mail.DeliverabilityEvent.new(:bounce, %{
          email: "slow@example.com",
          inactive: false,
          type: "SoftBounce"
        })

      assert Mail.handle_deliverability_event(event) == {:ok, :ignored}
      refute Mail.suppressed?("slow@example.com")
      refute Repo.one(Mail.Suppression)
    end

    test "a replayed bounce leaves exactly one row" do
      {:ok, event} =
        Mail.DeliverabilityEvent.new(:bounce, %{
          email: "dup@example.com",
          inactive: true,
          type: "HardBounce"
        })

      assert Mail.handle_deliverability_event(event) == {:ok, :suppressed}
      assert Mail.handle_deliverability_event(event) == {:ok, :suppressed}

      # Repo.one raises on a second row — the upsert refreshed the same one.
      assert Repo.one(Mail.Suppression).email == "dup@example.com"
    end

    test "an over-long description is trimmed to fit, and still suppresses" do
      {:ok, event} =
        Mail.DeliverabilityEvent.new(:bounce, %{
          email: "verbose@example.com",
          inactive: true,
          type: "HardBounce",
          description: String.duplicate("x", 5_000)
        })

      assert Mail.handle_deliverability_event(event) == {:ok, :suppressed}
      assert length(String.to_charlist(Repo.one(Mail.Suppression).detail)) == 1_000
    end

    # The derived "type: description" line is bounded by the same code-point
    # helper the command uses, so combining marks — which fold into a single
    # grapheme — cannot walk past the detail bound on the way out.
    test "a combining-mark description cannot outgrow the derived detail" do
      {:ok, event} =
        Mail.DeliverabilityEvent.new(:bounce, %{
          email: "marks@example.com",
          inactive: true,
          type: "HardBounce",
          description: "a" <> String.duplicate("\u0301", 3_000)
        })

      assert Mail.handle_deliverability_event(event) == {:ok, :suppressed}

      detail = Repo.one(Mail.Suppression).detail
      assert String.length(detail) < 1_000
      assert length(String.to_charlist(detail)) == 1_000
    end
  end

  describe "suppress/3" do
    test "records a suppression and returns it" do
      assert {:ok, suppression} = Mail.suppress("new@example.com", :hard_bounce, "HardBounce")
      assert suppression.reason == :hard_bounce
      assert suppression.detail == "HardBounce"
      assert Mail.suppressed?("new@example.com")
    end

    test "upserts by email — a later event refreshes the reason, never duplicates" do
      {:ok, _} = Mail.suppress("dupe@example.com", :hard_bounce, "bounce")
      {:ok, updated} = Mail.suppress("dupe@example.com", :spam_complaint, "complaint")

      assert updated.reason == :spam_complaint
      assert updated.detail == "complaint"
      assert Repo.aggregate(Mail.Suppression.Query.all(), :count) == 1
    end

    test "defaults the detail to nil when omitted" do
      assert {:ok, suppression} = Mail.suppress("nodetail@example.com", :spam_complaint)
      assert is_nil(suppression.detail)
    end

    test "a blank email is rejected" do
      assert {:error, changeset} = Mail.suppress("   ", :hard_bounce, nil)
      assert %{email: _} = errors_on(changeset)
    end
  end

  describe "the mailer skips suppressed recipients" do
    setup do
      %{user: Fixtures.Users.create_user()}
    end

    test "a suppressed address is not sent to", %{user: user} do
      {:ok, _} = Mail.suppress(user.email, :hard_bounce, "bounce")

      assert {:ok, %{suppressed: true}} = UserNotifier.deliver_magic_link(user, "tok", "123456")
    end

    test "a normal address is delivered, not suppressed", %{user: user} do
      assert {:ok, sent} = UserNotifier.deliver_magic_link(user, "tok", "123456")
      refute match?(%{suppressed: true}, sent)
    end
  end

  describe "branded return_to threading" do
    setup do
      %{user: Fixtures.Users.create_user()}
    end

    test "deliver_magic_link appends an encoded return_to when given one", %{user: user} do
      UserNotifier.deliver_magic_link(user, "tok", "ABC234", %RequestContext{}, "/app/acme")
      assert_email_sent(&(&1.text_body =~ "/sign_in/magic/tok/ABC234?return_to=%2Fapp%2Facme"))
    end

    test "deliver_magic_link without a return_to is unchanged", %{user: user} do
      UserNotifier.deliver_magic_link(user, "tok", "ABC234")

      assert_email_sent(
        &(&1.text_body =~ "/sign_in/magic/tok/ABC234" and not (&1.text_body =~ "return_to"))
      )
    end
  end

  describe "magic-link request context" do
    setup do
      %{user: Fixtures.Users.create_user()}
    end

    test "the sign-in email carries the time, IP, and a friendly device", %{user: user} do
      context = %RequestContext{
        ip_address: "203.0.113.7",
        user_agent:
          "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " <>
            "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36"
      }

      UserNotifier.deliver_magic_link(user, "tok", "ABC234", context)

      assert_email_sent(fn email ->
        email.text_body =~ "This sign-in was requested" and
          email.text_body =~ "203.0.113.7" and
          email.text_body =~ "Chrome on macOS" and
          email.text_body =~ "UTC"
      end)
    end

    test "omits the lines it has no data for (no IP / unparseable device)", %{user: user} do
      UserNotifier.deliver_magic_link(user, "tok", "ABC234", %RequestContext{})

      assert_email_sent(fn email ->
        email.text_body =~ "Time" and not (email.text_body =~ "Device")
      end)
    end
  end

  describe "confirmation email" do
    setup do
      %{user: Fixtures.Users.create_user()}
    end

    test "carries the subject, confirm link, sign-in link, and reassurance line", %{user: user} do
      UserNotifier.deliver_confirmation_instructions(user, "tok-confirm")

      assert_email_sent(fn email ->
        assert email.subject == "Confirm your emisar account"
        assert email.text_body =~ "/confirm/tok-confirm"
        assert email.text_body =~ "/sign_in"
        assert email.text_body =~ "If you didn't sign up"
        true
      end)
    end

    test "skips a suppressed recipient", %{user: user} do
      {:ok, _} = Mail.suppress(user.email, :hard_bounce, "bounce")

      assert {:ok, %{suppressed: true}} =
               UserNotifier.deliver_confirmation_instructions(user, "tok")
    end
  end

  describe "magic-link email content" do
    test "carries the subject, link, the code, and a 15-minute expiry" do
      user = Fixtures.Users.create_user()
      UserNotifier.deliver_magic_link(user, "tok-magic", "ABC234")

      assert_email_sent(fn email ->
        assert email.subject == "Your emisar sign-in code"
        assert email.text_body =~ "/sign_in/magic/tok-magic/ABC234"
        assert email.text_body =~ "ABC234"
        assert email.text_body =~ "15 minutes"
        assert email.html_body =~ ~s(href="http://localhost/sign_in/magic/tok-magic/ABC234")
        assert email.html_body =~ ~s(target="_top")
        assert email.html_body =~ ">Sign in to emisar</a>"
        true
      end)
    end

    test "escapes request context in the HTML alternative" do
      user = Fixtures.Users.create_user()
      context = %RequestContext{ip_address: ~s|<script>alert("x")</script>|}

      UserNotifier.deliver_magic_link(user, "tok-magic", "ABC234", context)

      assert_email_sent(fn email ->
        assert email.html_body =~ "&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;"
        refute email.html_body =~ "<script>"
        true
      end)
    end
  end

  describe "invitation email" do
    setup do
      %{invitee: Fixtures.Users.create_user()}
    end

    test "names the inviter and workspace and carries the accept + sign-in links", %{
      invitee: invitee
    } do
      inviter = Fixtures.Users.create_user(full_name: "Dana Inviter")
      account = Fixtures.Accounts.create_account(name: "Globex")

      UserNotifier.deliver_account_invitation(invitee, inviter, account, "tok-invite")

      assert_email_sent(fn email ->
        assert email.subject == "You're invited to Globex on emisar"
        assert email.text_body =~ "Dana Inviter"
        assert email.text_body =~ "Globex"
        assert email.text_body =~ "/accept_invitation/tok-invite"
        assert email.text_body =~ "/app/#{account.slug}/sign_in"
        assert email.text_body =~ "What is emisar?"
        true
      end)
    end

    test "falls back to the inviter's email when they have no full name", %{invitee: invitee} do
      inviter = Fixtures.Users.create_user(full_name: nil)
      account = Fixtures.Accounts.create_account(name: "Globex")

      UserNotifier.deliver_account_invitation(invitee, inviter, account, "tok")

      assert_email_sent(&(&1.text_body =~ inviter.email))
    end

    test "skips a suppressed invitee", %{invitee: invitee} do
      inviter = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()
      {:ok, _} = Mail.suppress(invitee.email, :spam_complaint, "complaint")

      assert {:ok, %{suppressed: true}} =
               UserNotifier.deliver_account_invitation(invitee, inviter, account, "tok")
    end
  end

  describe "approval-needed email content" do
    setup do
      approver = Fixtures.Users.create_user()
      account = Fixtures.Accounts.create_account()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: approver.id,
          role: "owner"
        )

      %{
        account: account,
        approver: approver,
        subject: Fixtures.Subjects.membership_subject(membership)
      }
    end

    test "surfaces action, runner name, reason, redacted args, and the approval link", %{
      account: account,
      subject: subject
    } do
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
        reason: "rotate the cert",
        matched_rules: ["high → approve"],
        account: account
      }

      UserNotifier.deliver_approval_request(subject, request, run)

      assert_email_sent(fn email ->
        assert email.subject == "Approval needed: caddy.reload_config"
        assert email.text_body =~ "caddy.reload_config"
        assert email.text_body =~ "edge-1"
        assert email.text_body =~ "rotate the cert"
        assert email.text_body =~ ~s("path": "/etc/caddy")
        assert email.text_body =~ ~s("token": "[REDACTED]")
        refute email.text_body =~ "secret-value"
        assert email.text_body =~ "people who can approve runs in this workspace."
        refute email.text_body =~ "decide_approval"
        assert email.text_body =~ "/app/#{account.slug}/approvals/req-id-123"
        refute email.text_body =~ "/app/approvals/req-id-123"
        true
      end)
    end

    test "labels a runner it cannot name by a truncated id", %{
      account: account,
      subject: subject
    } do
      persisted = Fixtures.Runs.create_run(account_id: account.id, action_id: "linux.uptime")
      {:ok, run} = Runs.fetch_run_by_id(persisted.id, subject)

      request = %{id: "req-id-9", reason: "x", matched_rules: [], account: account}

      UserNotifier.deliver_approval_request(subject, request, run)

      assert_email_sent(fn email ->
        assert email.text_body =~ "id #{String.slice(run.runner_id, 0, 8)}…"
        refute email.text_body =~ run.runner_id
        true
      end)
    end

    test "shows a non-secret placeholder when the arguments cannot be projected", %{
      account: account,
      subject: subject
    } do
      persisted = Fixtures.Runs.create_run(account_id: account.id)
      Fixtures.Runs.put_malformed_args_raw(persisted, ~s({"canary":"secret-value",}))
      {:ok, run} = Runs.fetch_run_by_id(persisted.id, subject, preload: [:runner])

      request = %{id: "req-id-7", reason: "x", matched_rules: [], account: account}

      UserNotifier.deliver_approval_request(subject, request, run)

      assert_email_sent(fn email ->
        assert email.text_body =~ "(unavailable)"
        refute email.text_body =~ "secret-value"
        refute email.text_body =~ "canary"
        true
      end)
    end

    test "renders the frozen runbook execution without leaking redacted arguments", %{
      approver: approver
    } do
      request = %{
        id: "req-execution-1",
        reason: "apply the reviewed settings",
        account: %{slug: "acme"},
        context: %{
          "execution_id" => "exec-123",
          "runbook" => %{"title" => "Database maintenance"},
          "plan" => %{
            "total_items" => 1,
            "stages" => [
              %{
                "id" => "apply",
                "title" => "Apply database change",
                "mode" => "parallel",
                "max_parallel" => 2,
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

      UserNotifier.deliver_runbook_execution_approval_request(approver, request)

      assert_email_sent(fn email ->
        assert email.subject == "Approval needed: Database maintenance"
        assert email.text_body =~ "Stages:    1"
        assert email.text_body =~ "Actions:   1"
        assert email.text_body =~ "Apply database change"
        assert email.text_body =~ "postgres.config_validate"
        assert email.text_body =~ "db-01"
        assert email.text_body =~ "postgres@1.4.2/sha256:"
        assert email.text_body =~ "[REDACTED]"
        assert email.text_body =~ "/app/acme/approvals/req-execution-1"
        refute email.text_body =~ "secret-value"
        true
      end)

      draft_request = put_in(request.context["execution_kind"], "draft_test")
      UserNotifier.deliver_runbook_execution_approval_request(approver, draft_request)

      assert_email_sent(fn email ->
        assert email.subject == "Approval needed: Draft test · Database maintenance"
        assert email.text_body =~ "Draft test · Database maintenance"
        true
      end)
    end

    test "skips a suppressed decider", %{
      account: account,
      approver: approver,
      subject: subject
    } do
      {:ok, _} = Mail.suppress(approver.email, :hard_bounce, "bounce")
      persisted = Fixtures.Runs.create_run(account_id: account.id)
      {:ok, run} = Runs.fetch_run_by_id(persisted.id, subject, preload: [:runner])
      request = %{id: "r", reason: "x", matched_rules: [], account: account}

      assert {:ok, %{suppressed: true}} =
               UserNotifier.deliver_approval_request(subject, request, run)
    end
  end

  describe "approval-decided email content" do
    setup do
      %{requester: Fixtures.Users.create_user()}
    end

    test "tells the requester an approve landed, with no argument values", %{
      requester: requester
    } do
      request = %{
        id: "req-decided-1",
        status: :approved,
        reason: "rotate the cert",
        decision_reason: "confirmed with the on-call",
        account: %{slug: "globex"},
        context: %{"action_id" => "caddy.reload_config", "args_sha256" => "abc"}
      }

      UserNotifier.deliver_approval_decision(requester, request)

      assert_email_sent(fn email ->
        assert email.subject == "Approved: caddy.reload_config"
        assert email.text_body =~ "was approved"
        assert email.text_body =~ "rotate the cert"
        assert email.text_body =~ "confirmed with the on-call"
        assert email.text_body =~ "/app/globex/approvals/req-decided-1"
        # The approval page is the only place arguments are shown.
        refute email.text_body =~ "Arguments"
        refute email.text_body =~ "abc"
        true
      end)
    end

    test "names the runbook and the denial when a whole execution is refused", %{
      requester: requester
    } do
      request = %{
        id: "req-decided-2",
        status: :denied,
        reason: "apply the reviewed settings",
        decision_reason: nil,
        account: %{slug: "acme"},
        context: %{"runbook" => %{"title" => "Database maintenance"}}
      }

      UserNotifier.deliver_approval_decision(requester, request)

      assert_email_sent(fn email ->
        assert email.subject == "Denied: Database maintenance"
        assert email.text_body =~ "was denied"
        assert email.text_body =~ "Decision note:   (none)"
        true
      end)
    end

    test "says nobody decided when the request timed out", %{requester: requester} do
      request = %{
        id: "req-decided-3",
        status: :expired,
        reason: "restart the checkout tier",
        decision_reason: nil,
        account: %{slug: "acme"},
        context: %{"action_id" => "linux.systemctl_restart"}
      }

      UserNotifier.deliver_approval_decision(requester, request)

      assert_email_sent(fn email ->
        assert email.subject == "Expired: linux.systemctl_restart"
        assert email.text_body =~ "expired before anyone decided"
        true
      end)
    end

    test "skips a suppressed requester", %{requester: requester} do
      {:ok, _} = Mail.suppress(requester.email, :hard_bounce, "bounce")

      request = %{
        id: "r",
        status: :approved,
        reason: "x",
        decision_reason: nil,
        account: %{slug: "acme"},
        context: %{"action_id" => "a"}
      }

      assert {:ok, %{suppressed: true}} =
               UserNotifier.deliver_approval_decision(requester, request)
    end
  end
end
