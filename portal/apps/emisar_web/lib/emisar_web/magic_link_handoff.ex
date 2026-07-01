defmodule EmisarWeb.MagicLinkHandoff do
  @moduledoc """
  The short-lived handoff that carries a magic-link sign-in from the code
  LiveView — which verifies the typed code but can't set the auth session cookie
  — to `UserSessionController.magic_link_complete`, which can.

  Signed with the endpoint secret (the same trust root as the magic cookie),
  valid for 30 seconds (the redirect is immediate). It is NOT a bearer credential
  on its own: `magic_link_complete` also requires the still-present magic cookie,
  binding completion to the originating browser — so a leaked handoff URL is
  useless in another browser, and a replay fails once the cookie is cleared.

  One seam wrapping `Phoenix.Token` (IL-19) so the handoff crypto has a single,
  testable review surface.
  """
  @salt "magic_link signin handoff"
  @max_age_seconds 30

  @doc "Signs `{user_id, registered?, token_id}` into an opaque handoff string."
  def sign(user_id, registered?, token_id)
      when is_binary(user_id) and is_boolean(registered?) and is_binary(token_id),
      do: Phoenix.Token.sign(EmisarWeb.Endpoint, @salt, {user_id, registered?, token_id})

  @doc "Verifies a handoff → `{:ok, {user_id, registered?, token_id}} | {:error, reason}`."
  def verify(handoff) when is_binary(handoff),
    do: Phoenix.Token.verify(EmisarWeb.Endpoint, @salt, handoff, max_age: @max_age_seconds)

  def verify(_), do: {:error, :invalid}
end
