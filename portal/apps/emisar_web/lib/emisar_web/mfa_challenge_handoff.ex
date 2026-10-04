defmodule EmisarWeb.MfaChallengeHandoff do
  @moduledoc """
  The short-lived handoff that carries a completed MFA sign-in challenge from
  `MfaChallengeLive` — which verifies the TOTP / recovery code but can't set the
  auth session cookie — to `UserSessionController.mfa_complete`, which can.

  What it carries is the opaque proof `Emisar.Auth.verify_mfa_challenge/3`
  returned — bound to the exact Member and enrollment that was verified — not a
  bare id. `Emisar.Auth` re-checks that proof against the locked Member row
  before it mints anything, so signing the proof (rather than a name) is what
  stops a handoff from outliving the credential state it was issued for.

  Signed with the endpoint secret, valid for 120 seconds (a slow authenticator
  lookup; the redirect itself is immediate). It also names the emailed code this
  browser verified as factor one, and `mfa_complete` requires both session
  markers to match it: `:mfa_pending_membership_id` the proof's Member and
  `:mfa_pending_magic_link_token_id` that exact code. Matching the Member alone
  was not enough: anyone who reads the inbox can pass factor one in a browser of
  their own, so a leaked handoff then finished their sign-in without a second
  factor. A code is consumed by the sign-in it completes, so a handoff finishes
  one sign-in, in the browser that earned it, and nothing else.

  One seam wrapping `Phoenix.Token` (IL-19) so the handoff crypto has a single,
  testable review surface.
  """
  @salt "mfa signin handoff"
  @max_age_seconds 120

  @doc """
  Signs a verified-MFA `proof`, with the id of the emailed code this browser
  verified, into an opaque handoff string.
  """
  def sign(proof, verified_token_id) when is_binary(verified_token_id),
    do: Phoenix.Token.sign(EmisarWeb.Endpoint, @salt, {proof, verified_token_id})

  @doc "Verifies a handoff → `{:ok, {proof, verified_token_id}} | {:error, reason}`."
  def verify(handoff) when is_binary(handoff) do
    case Phoenix.Token.verify(EmisarWeb.Endpoint, @salt, handoff, max_age: @max_age_seconds) do
      {:ok, {proof, token_id}} when is_binary(token_id) -> {:ok, {proof, token_id}}
      {:ok, _other} -> {:error, :invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify(_), do: {:error, :invalid}
end
