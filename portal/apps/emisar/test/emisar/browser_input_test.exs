defmodule Emisar.BrowserInputTest do
  use ExUnit.Case, async: true
  alias Emisar.BrowserInput

  describe "normalize/2" do
    test "blanks an empty optional string and parses a browser expiry, by either key shape" do
      normalized =
        BrowserInput.normalize(
          %{"description" => "   ", "expires_at" => "2026-12-25T10:00", "name" => "k"},
          blank: [:description],
          expiry: [:expires_at]
        )

      assert normalized == %{
               "description" => nil,
               "expires_at" => ~U[2026-12-25 10:00:00Z],
               "name" => "k"
             }

      assert BrowserInput.normalize(%{description: ""}, blank: [:description]) ==
               %{description: nil}
    end

    test "a field outside the spec passes through untouched" do
      assert BrowserInput.normalize(%{"note" => "  "}, blank: [:description]) == %{"note" => "  "}
    end
  end

  describe "expiry/1" do
    test "a browser minute stamp becomes UTC at that minute" do
      assert BrowserInput.expiry("2026-12-25T10:00") == ~U[2026-12-25 10:00:00Z]
    end

    test "blank means no expiry was typed" do
      assert BrowserInput.expiry("   ") == nil
    end

    # A malformed expiry must never quietly become "no expiry" — that would
    # mint a credential with no cutoff. Garbage passes through for Ecto's cast
    # to reject on the field.
    test "garbage and already-typed values pass through for Ecto to judge" do
      assert BrowserInput.expiry("not-a-date") == "not-a-date"
      assert BrowserInput.expiry(~U[2026-01-01 00:00:00Z]) == ~U[2026-01-01 00:00:00Z]
    end
  end
end
