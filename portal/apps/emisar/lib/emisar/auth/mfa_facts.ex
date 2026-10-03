defmodule Emisar.Auth.MfaFacts do
  @moduledoc """
  What the caller may know about their own second factor: whether it is on, how
  many recovery codes are left, and how the Member proves its own credential
  before adding an authenticator — `:email` (a code to its verified address),
  `:sso` (a fresh sign-in at the IdP behind its SSO session) or `:unavailable`.

  The TOTP secret and the recovery-code digests never appear here — a surface
  that renders enrollment state has no business holding either.
  """

  @enforce_keys [:enabled?, :recovery_codes_remaining, :enrollment_proof]
  defstruct [:enabled?, :recovery_codes_remaining, :enrollment_proof]

  @type t :: %__MODULE__{
          enabled?: boolean(),
          recovery_codes_remaining: non_neg_integer(),
          enrollment_proof: :email | :sso | :unavailable
        }
end
