defmodule EmisarWeb.MfaErrors do
  @moduledoc "The single source of the sentences shown when a code entry is refused — MFA enrollment, an MFA challenge or reset, an OIDC step-up, or a sign-in or device code — consumed by every page that renders one."

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
  #
  # The challenge, reset, step-up, and sign-in-code pages then grew the same
  # habit: the rate-limit sentence was retyped on four of them and had already
  # split into "then try again" and "and try again". Every code box now reads
  # its refusal from here.
  @messages %{
    invalid_otp: "That code didn't match. Try the latest code from your authenticator.",
    mfa_enrollment_proof_stale: "Your account changed. Verify your current email again.",
    session_not_found: "Your session changed. Sign in again before enabling MFA.",
    email_verification_required: "Request an email verification code first.",
    recovery_codes_unsaved: "Save your recovery codes before continuing.",
    rate_limited: "Too many attempts. Wait a few minutes, then try again.",
    email_rate_limited: "Too many code requests. Wait up to 15 minutes, then try again.",
    challenge_totp: "That code didn't match. Check your authenticator app and try again.",
    challenge_recovery: "That recovery code didn't match or has already been used.",
    step_up_factor_invalid: "That authenticator or recovery code didn't match. Try again.",
    email_code_invalid: "That code is incorrect or expired. Try again or request a new code."
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

  @doc "The sentence for a refused MFA challenge, by the factor the member was asked for."
  @spec challenge(:totp | :recovery) :: String.t()
  def challenge(:totp), do: message(:challenge_totp)
  def challenge(:recovery), do: message(:challenge_recovery)

  @doc "Every reason with a written sentence, for the test that pins them."
  @spec reasons() :: [atom()]
  def reasons, do: Map.keys(@messages)
end
