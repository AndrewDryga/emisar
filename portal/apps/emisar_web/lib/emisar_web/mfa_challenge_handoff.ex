defmodule EmisarWeb.MfaChallengeHandoff do
  @moduledoc """
  The short-lived handoff that carries a completed MFA sign-in challenge from
  `MfaChallengeLive` — which verifies the TOTP / recovery code but can't set the
  auth session cookie — to `UserSessionController.mfa_complete`, which can.

  What it carries is the opaque proof `Emisar.Auth.verify_mfa_challenge/3`
  returned — bound to the exact enrollment that was verified — not a bare user
  id. `Emisar.Auth` re-checks that proof against the locked user row before it
  mints anything, so signing the proof (rather than a name) is what stops a
  handoff from outliving the credential state it was issued for.

  Signed with the endpoint secret, valid for 120 seconds (a slow authenticator
  lookup; the redirect itself is immediate). It is NOT a bearer credential on its
  own: `mfa_complete` also requires the still-present `:mfa_pending_user_id`
  session marker to match the proof's user — binding completion to the browser
  that passed factor one. So a leaked handoff is useless without that partial
  session, and it can't manufacture a session for a user who never entered a
  second factor (the token is proof the LiveView actually ran the verification).

  One seam wrapping `Phoenix.Token` (IL-19) so the handoff crypto has a single,
  testable review surface.
  """
  @salt "mfa signin handoff"
  @max_age_seconds 120

  @doc "Signs a verified-MFA `proof` into an opaque handoff string."
  def sign(proof), do: Phoenix.Token.sign(EmisarWeb.Endpoint, @salt, proof)

  @doc "Verifies a handoff → `{:ok, proof} | {:error, reason}`."
  def verify(handoff) when is_binary(handoff),
    do: Phoenix.Token.verify(EmisarWeb.Endpoint, @salt, handoff, max_age: @max_age_seconds)

  def verify(_), do: {:error, :invalid}
end
