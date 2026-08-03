defmodule Emisar.Auth.MfaFacts do
  @moduledoc """
  What the caller may know about their own second factor: whether it is on and
  how many recovery codes are left.

  The TOTP secret and the recovery-code digests never appear here — a surface
  that renders enrollment state has no business holding either.
  """

  @enforce_keys [:enabled?, :recovery_codes_remaining]
  defstruct [:enabled?, :recovery_codes_remaining]

  @type t :: %__MODULE__{enabled?: boolean(), recovery_codes_remaining: non_neg_integer()}
end
