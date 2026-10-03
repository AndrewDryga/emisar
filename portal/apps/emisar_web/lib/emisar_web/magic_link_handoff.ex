defmodule EmisarWeb.MagicLinkHandoff do
  @moduledoc """
  The short-lived handoff that carries an emailed-code sign-in from the code
  LiveView — which verifies the typed code but can't set the session cookie —
  to `UserSessionController.magic_link_complete`, which can.

  It carries what `Emisar.Auth.verify_magic_link/4` returned: the Member the
  code proved (`nil` for a sign-up code, which has no Member yet) and the
  verified code's id. Signed with the endpoint secret, valid for 30 seconds
  (the redirect is immediate). It is NOT a bearer credential on its own:
  `magic_link_complete` also requires the still-present magic cookie naming the
  same code, binding completion to the originating browser — so a leaked
  handoff URL is useless in another browser, and a replay fails once the cookie
  is cleared.

  One seam wrapping `Phoenix.Token` (IL-19) so the handoff crypto has a single,
  testable review surface.
  """
  @salt "magic_link signin handoff"
  @max_age_seconds 30

  @doc "Signs `{membership_id | nil, token_id}` into an opaque handoff string."
  def sign(membership_id, token_id)
      when (is_binary(membership_id) or is_nil(membership_id)) and is_binary(token_id),
      do: Phoenix.Token.sign(EmisarWeb.Endpoint, @salt, {membership_id, token_id})

  @doc "Verifies a handoff → `{:ok, {membership_id | nil, token_id}} | {:error, reason}`."
  def verify(handoff) when is_binary(handoff) do
    case Phoenix.Token.verify(EmisarWeb.Endpoint, @salt, handoff, max_age: @max_age_seconds) do
      {:ok, {membership_id, token_id}}
      when (is_binary(membership_id) or is_nil(membership_id)) and is_binary(token_id) ->
        {:ok, {membership_id, token_id}}

      {:ok, _other} ->
        {:error, :invalid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def verify(_), do: {:error, :invalid}
end
