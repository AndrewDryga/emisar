defmodule EmisarWeb.MfaErrorsTest do
  @moduledoc """
  Pins the one place an MFA enrollment refusal is worded.

  The forced interstitial and the self-service profile page run the same flow
  against the same `Emisar.Auth` functions, and their hand-written copies had
  drifted: a rejected code said "That code didn't match — try the next one." on
  one and "Invalid code — try the next one." on the other, and only one offered
  "Try again." after a failed write.
  """
  use ExUnit.Case, async: true
  alias EmisarWeb.MfaErrors

  describe "message/1" do
    test "every written reason has a non-empty sentence" do
      for reason <- MfaErrors.reasons() do
        assert MfaErrors.message(reason) != "", "#{reason} has no sentence"
      end
    end

    test "an unmapped atom still reaches the member as something actionable" do
      assert MfaErrors.message(:some_error_nobody_has_worded_yet) ==
               "Could not enable MFA. Try again."
    end

    test "a changeset reads as the same failed write, not a field error" do
      # The enrollment form is one code box, so there is nothing to hang a field
      # error off — it says what happened and what to do instead.
      assert MfaErrors.message(%Ecto.Changeset{}) == "Could not enable MFA. Try again."
    end

    test "a rejected code is worded once, for both enrollment surfaces" do
      assert MfaErrors.message(:invalid_otp) == "That code didn't match — try the next one."
    end
  end

  describe "the enrollment surfaces" do
    # The drift these files used to carry was invisible until someone read both.
    # This asserts the sentences are no longer written in either page.
    @sources [
      "lib/emisar_web/live/mfa_setup_live.ex",
      "lib/emisar_web/live/profile_live.ex"
    ]

    test "neither page hand-writes a sentence MfaErrors owns" do
      for relative <- @sources, reason <- MfaErrors.reasons() do
        source = File.read!(Path.join(__DIR__, "../../" <> relative))
        sentence = MfaErrors.message(reason)

        refute String.contains?(source, "\"" <> sentence <> "\""),
               "#{relative} still spells out the #{reason} sentence; call MfaErrors.message/1"
      end
    end
  end
end
