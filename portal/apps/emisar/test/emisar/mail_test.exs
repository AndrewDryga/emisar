defmodule Emisar.MailTest do
  @moduledoc """
  The email-suppression store: addresses that hard-bounced or complained
  are recorded (from the Postmark webhook) and the transactional mailer
  skips them on its next send.
  """
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

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
end
