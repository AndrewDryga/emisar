defmodule Emisar.Mail.DeliverabilityEventTest do
  @moduledoc """
  The provider-neutral deliverability command a mail webhook maps its payload
  onto: it accepts only the reports the domain acts on, and a built command is
  bounded by construction.
  """
  use ExUnit.Case, async: true
  alias Emisar.Mail.DeliverabilityEvent

  describe "new/2" do
    test "builds a bounce for a deactivated address" do
      attrs = %{
        email: "dead@example.com",
        inactive: true,
        type: "HardBounce",
        description: "no such mailbox"
      }

      assert {:ok, event} = DeliverabilityEvent.new(:bounce, attrs)
      assert event.kind == :bounce
      assert event.email == "dead@example.com"
      assert event.inactive == true
      assert event.type == "HardBounce"
      assert event.description == "no such mailbox"
    end

    test "builds a transient bounce" do
      attrs = %{email: "slow@example.com", inactive: false, type: "SoftBounce"}

      assert {:ok, event} = DeliverabilityEvent.new(:bounce, attrs)
      assert event.inactive == false
      assert is_nil(event.description)
    end

    test "builds a spam complaint, which carries no deactivation" do
      assert {:ok, event} =
               DeliverabilityEvent.new(:spam_complaint, %{email: "angry@example.com"})

      assert event.kind == :spam_complaint
      assert is_nil(event.inactive)
    end

    test "trims the reported address" do
      assert {:ok, event} =
               DeliverabilityEvent.new(:spam_complaint, %{email: "  padded@example.com  "})

      assert event.email == "padded@example.com"
    end

    test "rejects a kind the domain has no policy for" do
      attrs = %{email: "delivered@example.com"}

      assert DeliverabilityEvent.new(:delivery, attrs) ==
               {:error, :invalid_deliverability_event}
    end

    test "rejects a bounce whose deactivation is missing or not a boolean" do
      assert DeliverabilityEvent.new(:bounce, %{email: "x@example.com"}) ==
               {:error, :invalid_deliverability_event}

      assert DeliverabilityEvent.new(:bounce, %{email: "x@example.com", inactive: "true"}) ==
               {:error, :invalid_deliverability_event}
    end

    test "rejects a blank or non-binary address" do
      assert DeliverabilityEvent.new(:spam_complaint, %{email: "   "}) ==
               {:error, :invalid_deliverability_event}

      assert DeliverabilityEvent.new(:spam_complaint, %{}) ==
               {:error, :invalid_deliverability_event}

      assert DeliverabilityEvent.new(:spam_complaint, %{email: 42}) ==
               {:error, :invalid_deliverability_event}
    end

    test "rejects an address over 320 code points rather than truncating an identity" do
      local = String.duplicate("a", 308)

      assert {:ok, event} =
               DeliverabilityEvent.new(:spam_complaint, %{email: local <> "@example.com"})

      assert length(String.to_charlist(event.email)) == 320

      assert DeliverabilityEvent.new(:spam_complaint, %{email: local <> "b@example.com"}) ==
               {:error, :invalid_deliverability_event}
    end

    test "rejects an address whose combining marks push it past 320 code points" do
      email = "a" <> String.duplicate("\u0301", 400) <> "@example.com"

      # Combining marks fold into their base grapheme, so a grapheme-counted
      # bound sees a short address where the database counts 413 characters.
      assert String.length(email) <= 320
      assert length(String.to_charlist(email)) > 320

      assert DeliverabilityEvent.new(:spam_complaint, %{email: email}) ==
               {:error, :invalid_deliverability_event}
    end

    test "rejects a malformed address" do
      for email <- ["no-at-sign", "spaced out@example.com", "gap@ example.com"] do
        assert DeliverabilityEvent.new(:spam_complaint, %{email: email}) ==
                 {:error, :invalid_deliverability_event}
      end
    end

    test "rejects an address carrying an ASCII control code point" do
      for email <- ["nul\0@example.com", "bell\a@example.com", "del\d@example.com"] do
        assert DeliverabilityEvent.new(:spam_complaint, %{email: email}) ==
                 {:error, :invalid_deliverability_event}
      end
    end

    test "bounds long diagnostics and discards non-binary ones" do
      attrs = %{
        email: "verbose@example.com",
        inactive: true,
        type: String.duplicate("t", 1_500),
        description: String.duplicate("d", 5_000)
      }

      assert {:ok, event} = DeliverabilityEvent.new(:bounce, attrs)
      assert length(String.to_charlist(event.type)) == 1_000
      assert length(String.to_charlist(event.description)) == 1_000

      assert {:ok, event} =
               DeliverabilityEvent.new(:bounce, %{
                 email: "odd@example.com",
                 inactive: true,
                 type: %{"unexpected" => "shape"},
                 description: 12
               })

      assert is_nil(event.type)
      assert is_nil(event.description)
    end

    test "bounds a combining-mark diagnostic by code points, not graphemes" do
      attrs = %{
        email: "marks@example.com",
        inactive: true,
        type: "a" <> String.duplicate("\u0301", 3_000),
        description: "b" <> String.duplicate("\u0301", 3_000)
      }

      assert {:ok, event} = DeliverabilityEvent.new(:bounce, attrs)
      assert length(String.to_charlist(event.type)) == 1_000
      assert length(String.to_charlist(event.description)) == 1_000
    end
  end

  describe "bound_diagnostic/1" do
    test "leaves a diagnostic already inside the bound alone" do
      assert DeliverabilityEvent.bound_diagnostic("no such mailbox") == "no such mailbox"
    end

    test "truncates to exactly 1,000 code points" do
      # One base character plus thousands of combining marks is a SINGLE
      # grapheme, so a grapheme bound would pass 3,001 characters through.
      diagnostic = "a" <> String.duplicate("\u0301", 3_000)

      assert String.length(diagnostic) == 1
      assert length(String.to_charlist(DeliverabilityEvent.bound_diagnostic(diagnostic))) == 1_000
    end
  end
end
