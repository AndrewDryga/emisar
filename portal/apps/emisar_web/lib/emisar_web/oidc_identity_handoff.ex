defmodule EmisarWeb.OIDCIdentityHandoff do
  @moduledoc """
  Short-lived, CSRF-protected handoff from an inline LiveView step-up to the
  controller that can write the OIDC transaction into the encrypted session.
  The domain rechecks every embedded identity, purpose, proof, and session
  binding before redirect and again before the callback mutation.
  """
  @salt "oidc identity handoff"
  @max_age_seconds 120

  def sign(payload) when is_map(payload),
    do: Phoenix.Token.sign(EmisarWeb.Endpoint, @salt, payload)

  def verify(handoff) when is_binary(handoff) do
    case Phoenix.Token.verify(EmisarWeb.Endpoint, @salt, handoff, max_age: @max_age_seconds) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _other -> {:error, :invalid}
    end
  end

  def verify(_handoff), do: {:error, :invalid}
end
