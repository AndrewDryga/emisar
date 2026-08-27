defmodule EmisarWeb.MfaErrors do
  @moduledoc "The single source of the sentence shown when MFA enrollment is refused — consumed by the forced-enrollment interstitial and the self-service profile page."

  # Two pages run the same enrollment against the same Emisar.Auth functions:
  # MfaSetupLive when an account enforces MFA, ProfileLive when a member opts in.
  # Each had grown its own mapping of the same domain error atoms, and they had
  # drifted — the same rejected code read "That code didn't match — try the next
  # one." on one page and "Invalid code — try the next one." on the other, and
  # the same failed write offered "Try again." only on one of them.
  #
  # Only the SENTENCE lives here. How each page delivers it stays with the page:
  # the interstitial has no roster to flash over and shows most of these inline,
  # and it leaves via a full redirect where the profile page can patch. Those are
  # real differences between the two surfaces, not drift.
  @messages %{
    invalid_otp: "That code didn't match — try the next one.",
    mfa_enrollment_proof_stale: "Your account changed. Verify your current email again.",
    session_not_found: "Your session changed. Sign in again before enabling MFA.",
    email_verification_required: "Email a verification code first.",
    recovery_codes_unsaved: "Save your recovery codes before continuing."
  }

  # An enrollment write that fails validation is not something the member can
  # read a field error off — the form is one code box — so it says what happened
  # and what to do about it.
  @unknown "Could not enable MFA. Try again."

  @doc "The member-facing sentence for one refused enrollment step."
  @spec message(term()) :: String.t()
  def message(%Ecto.Changeset{}), do: @unknown

  def message(reason) when is_atom(reason) do
    case Map.fetch(@messages, reason) do
      {:ok, message} -> message
      :error -> @unknown
    end
  end

  def message(_reason), do: @unknown

  @doc "Every reason with a written sentence, for the test that pins them."
  @spec reasons() :: [atom()]
  def reasons, do: Map.keys(@messages)
end
