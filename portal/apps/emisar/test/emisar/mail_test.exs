defmodule Emisar.MailTest do
  @moduledoc """
  The email-suppression store: addresses that hard-bounced or complained
  are recorded (from the Postmark webhook) and the transactional mailer
  skips them on its next send.
  """
  use Emisar.DataCase, async: true

  import Emisar.Fixtures
  import Swoosh.TestAssertions

  alias Emisar.Mail
  alias Emisar.Mailers.UserNotifier

  describe "suppress/3 + suppressed?/1" do
    test "records a suppression and reports it case-insensitively" do
      assert {:ok, suppression} = Mail.suppress("Bounced@Example.com", :hard_bounce, "HardBounce")
      assert suppression.reason == :hard_bounce

      # citext key → case-insensitive match.
      assert Mail.suppressed?("bounced@example.com")
      assert Mail.suppressed?("BOUNCED@EXAMPLE.COM")
      refute Mail.suppressed?("someone-else@example.com")
    end

    test "upserts by email — a later event refreshes the reason, never duplicates" do
      {:ok, _} = Mail.suppress("dupe@example.com", :hard_bounce, "bounce")
      {:ok, updated} = Mail.suppress("dupe@example.com", :spam_complaint, "complaint")

      assert updated.reason == :spam_complaint
      assert updated.detail == "complaint"
      assert Repo.aggregate(Mail.Suppression.Query.all(), :count) == 1
    end

    test "a blank email is rejected" do
      assert {:error, changeset} = Mail.suppress("   ", :hard_bounce, nil)
      assert %{email: _} = errors_on(changeset)
    end

    test "suppressed?/1 is false for a non-binary" do
      refute Mail.suppressed?(nil)
    end

    test "suppressed_emails/1 returns the suppressed subset, keyed to the caller's strings" do
      {:ok, _} = Mail.suppress("bounced@example.com", :hard_bounce, "bounce")
      {:ok, _} = Mail.suppress("complained@example.com", :spam_complaint, "complaint")

      # Given the caller's own (differing) casing; the result keeps the INPUT
      # strings so a render check against them is exact, while the match itself
      # is case-insensitive (citext + the downcase reconciliation).
      result =
        Mail.suppressed_emails([
          "Bounced@Example.com",
          "complained@example.com",
          "fine@example.com"
        ])

      assert result == MapSet.new(["Bounced@Example.com", "complained@example.com"])
    end

    test "suppressed_emails/1 is empty for an empty list" do
      assert Mail.suppressed_emails([]) == MapSet.new()
    end

    test "suppressed_emails/1 drops nil/blank entries (SSO members have no email)" do
      {:ok, _} = Mail.suppress("bounced@example.com", :hard_bounce, "bounce")

      # A list with only nils (e.g. an all-SSO team) must not reach the query.
      assert Mail.suppressed_emails([nil, nil]) == MapSet.new()

      # A mix of nil + real addresses still resolves the real ones.
      result = Mail.suppressed_emails([nil, "bounced@example.com", "  ", "fine@example.com"])
      assert result == MapSet.new(["bounced@example.com"])
    end
  end

  describe "the mailer skips suppressed recipients" do
    test "a suppressed address is not sent to" do
      user = user_fixture()
      {:ok, _} = Mail.suppress(user.email, :hard_bounce, "bounce")

      # The skip path returns {:ok, %{suppressed: true}} without building an
      # email — proof the send was suppressed, not delivered.
      assert {:ok, %{suppressed: true}} = UserNotifier.deliver_magic_link(user, "tok")
    end

    test "a normal address is delivered, not suppressed" do
      user = user_fixture()
      assert {:ok, sent} = UserNotifier.deliver_magic_link(user, "tok")
      refute match?(%{suppressed: true}, sent)
    end
  end

  describe "branded return_to threading" do
    test "deliver_magic_link appends an encoded return_to when given one" do
      user = user_fixture()
      UserNotifier.deliver_magic_link(user, "tok", "/app/acme")
      assert_email_sent(&(&1.text_body =~ "/sign_in/magic/tok?return_to=%2Fapp%2Facme"))
    end

    test "deliver_magic_link without a return_to is unchanged" do
      user = user_fixture()
      UserNotifier.deliver_magic_link(user, "tok")

      assert_email_sent(
        &(&1.text_body =~ "/sign_in/magic/tok" and not (&1.text_body =~ "return_to"))
      )
    end

    test "deliver_password_reset appends an encoded return_to when given one" do
      user = user_fixture()
      UserNotifier.deliver_password_reset(user, "tok", "/app/acme")
      assert_email_sent(&(&1.text_body =~ "/reset_password/tok?return_to=%2Fapp%2Facme"))
    end
  end

  describe "welcome email" do
    test "carries the team name + branded sign-in link" do
      user = user_fixture()

      {:ok, account} =
        Emisar.Accounts.create_account_with_owner(%{name: "Acme Co", slug: "acme-co"}, user)

      UserNotifier.deliver_welcome(user, account)

      assert_email_sent(fn email ->
        assert email.subject == "Your emisar workspace is ready"
        assert email.text_body =~ "Acme Co"
        assert email.text_body =~ "/app/#{account.slug}/sign_in"
        true
      end)
    end

    # an owner who signed up without a name is greeted
    # by email rather than rendering a blank salutation.
    test "falls back to the email when the owner has no full name" do
      user = user_fixture(full_name: nil)

      {:ok, account} =
        Emisar.Accounts.create_account_with_owner(%{name: "Nameless", slug: "nameless"}, user)

      UserNotifier.deliver_welcome(user, account)

      assert_email_sent(&(&1.text_body =~ "Welcome to emisar, #{user.email}!"))
    end
  end

  describe "confirmation email" do
    # the sign-up confirmation carries its subject, the
    # absolute /confirm/<token> link, and the "ignore if you didn't sign up" line.
    test "carries the subject, confirm link, and reassurance line" do
      user = user_fixture()
      UserNotifier.deliver_confirmation_instructions(user, "tok-confirm")

      assert_email_sent(fn email ->
        assert email.subject == "Confirm your emisar account"
        assert email.text_body =~ "/confirm/tok-confirm"
        assert email.text_body =~ "If you didn't sign up"
        true
      end)
    end

    # a suppressed address is skipped with the shared
    # {:ok, %{suppressed: true}} contract; no email is built.
    test "skips a suppressed recipient" do
      user = user_fixture()
      {:ok, _} = Mail.suppress(user.email, :hard_bounce, "bounce")

      assert {:ok, %{suppressed: true}} =
               UserNotifier.deliver_confirmation_instructions(user, "tok")
    end
  end

  describe "magic-link email content" do
    # + — the magic-link subject, the
    # /sign_in/magic/<token> link, and the body copy "15 minutes" which
    # AGREES with the enforced @magic_link_validity_in_minutes (unlike the
    # reset email, see).
    test "carries the subject, link, and a 15-minute expiry that matches enforcement" do
      user = user_fixture()
      UserNotifier.deliver_magic_link(user, "tok-magic")

      assert_email_sent(fn email ->
        assert email.subject == "Your emisar magic link"
        assert email.text_body =~ "/sign_in/magic/tok-magic"
        assert email.text_body =~ "15 minutes"
        true
      end)
    end
  end

  describe "password-reset email content" do
    # the reset subject, the /reset_password/<token>
    # link, and the "won't change unless someone clicks" reassurance.
    test "carries the subject, reset link, and reassurance line" do
      user = user_fixture()
      UserNotifier.deliver_password_reset(user, "tok-reset")

      assert_email_sent(fn email ->
        assert email.subject == "Reset your emisar password"
        assert email.text_body =~ "/reset_password/tok-reset"
        assert email.text_body =~ "won't change unless someone clicks"
        true
      end)
    end

    # DOCUMENTED DEFECT CANDIDATE. The body promises the
    # link is "valid for 1 hour", but the enforced reset-token TTL is
    # @reset_validity_in_days = 1 (≈24h) at the Auth layer. This test pins the
    # current copy so the mismatch is visible; once a product decision picks
    # the correct value, flip this to assert the body and the enforced TTL
    # AGREE. Not changed in discovery (no production edit).
    test "body still says '1 hour' though the link actually works ~1 day (mismatch)" do
      user = user_fixture()
      UserNotifier.deliver_password_reset(user, "tok")

      assert_email_sent(fn email ->
        assert email.text_body =~ "valid for 1 hour"
        # The enforced window is 1 DAY — the body copy and enforcement disagree.
        refute email.text_body =~ "1 day"
        refute email.text_body =~ "24 hours"
        true
      end)
    end
  end

  describe "invitation email" do
    # the invite subject names the workspace, the body
    # names the inviter + workspace, carries the /accept_invitation/<token>
    # link and the "what is emisar?" pitch.
    test "names the inviter and workspace and carries the accept link" do
      inviter = user_fixture(full_name: "Dana Inviter")
      invitee = user_fixture()
      account = account_fixture(name: "Globex")

      UserNotifier.deliver_account_invitation(invitee, inviter, account, "tok-invite")

      assert_email_sent(fn email ->
        assert email.subject == "You're invited to Globex on emisar"
        assert email.text_body =~ "Dana Inviter"
        assert email.text_body =~ "Globex"
        assert email.text_body =~ "/accept_invitation/tok-invite"
        assert email.text_body =~ "What is emisar?"
        true
      end)
    end

    # an inviter with no full_name is shown by email.
    test "falls back to the inviter's email when they have no full name" do
      inviter = user_fixture(full_name: nil)
      invitee = user_fixture()
      account = account_fixture(name: "Globex")

      UserNotifier.deliver_account_invitation(invitee, inviter, account, "tok")

      assert_email_sent(&(&1.text_body =~ inviter.email))
    end

    # a suppressed invitee is skipped (the membership row
    # is created elsewhere; here only the send is suppressed).
    test "skips a suppressed invitee" do
      inviter = user_fixture()
      invitee = user_fixture()
      account = account_fixture()
      {:ok, _} = Mail.suppress(invitee.email, :spam_complaint, "complaint")

      assert {:ok, %{suppressed: true}} =
               UserNotifier.deliver_account_invitation(invitee, inviter, account, "tok")
    end
  end

  describe "approval-needed email content" do
    # (body content) — the approval email surfaces enough
    # to decide from the inbox: subject with the action_id, the runner NAME
    # (not the opaque id), the operator's reason, an args preview, and the
    # /app/approvals/<id> link. (Recipient targeting is covered in approvals_test.)
    test "surfaces action, runner name, reason, args, and the approval link" do
      approver = user_fixture()
      request = %{id: "req-id-123", reason: "rotate the cert", matched_rules: ["high → approve"]}

      run = %{
        action_id: "caddy.reload_config",
        runner: %{name: "edge-1"},
        runner_id: "rnr-abc",
        policy_reason: "high risk",
        matched_rules: ["high → approve"],
        args: %{"path" => "/etc/caddy"}
      }

      UserNotifier.deliver_approval_request(approver, request, run)

      assert_email_sent(fn email ->
        assert email.subject == "Approval needed: caddy.reload_config"
        assert email.text_body =~ "caddy.reload_config"
        assert email.text_body =~ "edge-1"
        assert email.text_body =~ "rotate the cert"
        assert email.text_body =~ "/etc/caddy"
        assert email.text_body =~ "/app/approvals/req-id-123"
        true
      end)
    end

    # a run on a runner with no name falls back to a
    # truncated-id label, never a blank or the raw full id.
    test "labels an unnamed runner by a truncated id" do
      approver = user_fixture()
      request = %{id: "req-id-9", reason: "x", matched_rules: []}

      run = %{
        action_id: "linux.uptime",
        runner: %{name: ""},
        runner_id: "abcdef0123456789",
        policy_reason: nil,
        matched_rules: [],
        args: %{}
      }

      UserNotifier.deliver_approval_request(approver, request, run)

      assert_email_sent(fn email ->
        assert email.text_body =~ "id abcdef01…"
        refute email.text_body =~ "abcdef0123456789"
        true
      end)
    end

    # a suppressed decider is skipped via the same
    # shared deliver/3; other recipients are unaffected (covered elsewhere).
    test "skips a suppressed decider" do
      approver = user_fixture()
      {:ok, _} = Mail.suppress(approver.email, :hard_bounce, "bounce")
      request = %{id: "r", reason: "x", matched_rules: []}
      run = %{action_id: "a", runner: %{name: "n"}, runner_id: "i", policy_reason: nil, args: %{}}

      assert {:ok, %{suppressed: true}} =
               UserNotifier.deliver_approval_request(approver, request, run)
    end
  end
end
