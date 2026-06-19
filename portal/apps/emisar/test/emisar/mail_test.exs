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
end
