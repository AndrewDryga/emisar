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

  describe "suppressed?/1" do
    test "reports a suppressed address case-insensitively (citext key)" do
      {:ok, _} = Mail.suppress("Bounced@Example.com", :hard_bounce, "HardBounce")

      # citext key → the stored casing doesn't matter on lookup.
      assert Mail.suppressed?("bounced@example.com")
      assert Mail.suppressed?("BOUNCED@EXAMPLE.COM")
      refute Mail.suppressed?("someone-else@example.com")
    end

    test "trims the input before the lookup" do
      {:ok, _} = Mail.suppress("trim@example.com", :hard_bounce, "bounce")

      # The mailer may hand a padded address; suppressed? String.trims it first.
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

    test "is empty for an empty list" do
      assert Mail.suppressed_emails([]) == MapSet.new()
    end

    test "drops nil/blank entries (SSO members have no email)" do
      {:ok, _} = Mail.suppress("bounced@example.com", :hard_bounce, "bounce")

      # A list with only nils (e.g. an all-SSO team) must not reach the query.
      assert Mail.suppressed_emails([nil, nil]) == MapSet.new()

      # A mix of nil + real addresses still resolves the real ones.
      result = Mail.suppressed_emails([nil, "bounced@example.com", "  ", "fine@example.com"])
      assert result == MapSet.new(["bounced@example.com"])
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

      # The skip path returns {:ok, %{suppressed: true}} without building an
      # email — proof the send was suppressed, not delivered.
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
        # A recipient can tell their own sign-in from a stranger's: when, where,
        # and a parsed device — not the raw User-Agent string.
        email.text_body =~ "This sign-in was requested" and
          email.text_body =~ "203.0.113.7" and
          email.text_body =~ "Chrome on macOS" and
          email.text_body =~ "UTC"
      end)
    end

    test "omits the lines it has no data for (no IP / unparseable device)", %{user: user} do
      UserNotifier.deliver_magic_link(user, "tok", "ABC234", %RequestContext{})

      # Time is always present; the Device line (block-only wording) is dropped
      # rather than shown blank. ("From" also appears in the body prose, so the
      # unambiguous Device label is the one to assert on.)
      assert_email_sent(fn email ->
        email.text_body =~ "Time" and not (email.text_body =~ "Device")
      end)
    end
  end

  describe "welcome email" do
    test "carries the team name + branded sign-in link" do
      user = Fixtures.Users.create_user()

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
      user = Fixtures.Users.create_user(full_name: nil)

      {:ok, account} =
        Emisar.Accounts.create_account_with_owner(%{name: "Nameless", slug: "nameless"}, user)

      UserNotifier.deliver_welcome(user, account)

      assert_email_sent(&(&1.text_body =~ "Welcome to emisar, #{user.email}!"))
    end
  end

  describe "confirmation email" do
    setup do
      %{user: Fixtures.Users.create_user()}
    end

    # the sign-up confirmation carries its subject, the
    # absolute /confirm/<token> link, a universal sign-in link (so the recipient
    # is never stranded), and the "ignore if you didn't sign up" line.
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

    # a suppressed address is skipped with the shared
    # {:ok, %{suppressed: true}} contract; no email is built.
    test "skips a suppressed recipient", %{user: user} do
      {:ok, _} = Mail.suppress(user.email, :hard_bounce, "bounce")

      assert {:ok, %{suppressed: true}} =
               UserNotifier.deliver_confirmation_instructions(user, "tok")
    end
  end

  describe "magic-link email content" do
    # The magic-link subject, the /sign_in/magic/<token>/<code> link, and the
    # body copy "15 minutes" which AGREES with the enforced
    # @magic_link_validity_in_minutes.
    test "carries the subject, link, the code, and a 15-minute expiry" do
      user = Fixtures.Users.create_user()
      UserNotifier.deliver_magic_link(user, "tok-magic", "ABC234")

      assert_email_sent(fn email ->
        assert email.subject == "Your emisar sign-in code"
        assert email.text_body =~ "/sign_in/magic/tok-magic/ABC234"
        # The code is shown standalone for cross-device entry.
        assert email.text_body =~ "ABC234"
        assert email.text_body =~ "15 minutes"
        true
      end)
    end
  end

  describe "invitation email" do
    setup do
      %{invitee: Fixtures.Users.create_user()}
    end

    # the invite subject names the workspace, the body
    # names the inviter + workspace, carries the /accept_invitation/<token>
    # link, the team's branded sign-in link (where they sign in after accepting),
    # and the "what is emisar?" pitch.
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

    # an inviter with no full_name is shown by email.
    test "falls back to the inviter's email when they have no full name", %{invitee: invitee} do
      inviter = Fixtures.Users.create_user(full_name: nil)
      account = Fixtures.Accounts.create_account(name: "Globex")

      UserNotifier.deliver_account_invitation(invitee, inviter, account, "tok")

      assert_email_sent(&(&1.text_body =~ inviter.email))
    end

    # a suppressed invitee is skipped (the membership row
    # is created elsewhere; here only the send is suppressed).
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
      %{approver: Fixtures.Users.create_user()}
    end

    # (body content) — the approval email surfaces enough
    # to decide from the inbox: subject with the action_id, the runner NAME
    # (not the opaque id), the operator's reason, an args preview, and the
    # /app/approvals/<id> link. (Recipient targeting is covered in approvals_test.)
    test "surfaces action, runner name, reason, args, and the approval link", %{
      approver: approver
    } do
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
    test "labels an unnamed runner by a truncated id", %{approver: approver} do
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
    test "skips a suppressed decider", %{approver: approver} do
      {:ok, _} = Mail.suppress(approver.email, :hard_bounce, "bounce")
      request = %{id: "r", reason: "x", matched_rules: []}
      run = %{action_id: "a", runner: %{name: "n"}, runner_id: "i", policy_reason: nil, args: %{}}

      assert {:ok, %{suppressed: true}} =
               UserNotifier.deliver_approval_request(approver, request, run)
    end
  end
end
