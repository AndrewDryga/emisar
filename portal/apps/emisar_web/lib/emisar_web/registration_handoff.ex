defmodule EmisarWeb.RegistrationHandoff do
  @moduledoc """
  The short-lived handoff from the signup LiveView to the magic-link controller.

  `UserSignUpLive` creates the unconfirmed user, then encrypts its id and the
  validated workspace + profile intent before the browser submits to
  `UserSessionController.magic_link_start`. The controller copies that intent
  only onto the exact server-side magic factor when the id matches the email's
  user. Final session minting creates the workspace in the same transaction.
  Existing-email attempts carry a same-shaped decoy handoff, so neither a public
  account/slug nor the browser response reveals which branch signup took.

  The handoff is encrypted, not merely signed: both the newly-created user id
  and a same-length decoy cross the browser, and neither may reveal which branch
  signup took. One seam wrapping `Phoenix.Token` (IL-19) keeps that crypto
  testable in one place.
  """
  alias Emisar.Auth

  @salt "registration magic handoff"
  @max_age_seconds Auth.magic_link_validity_in_minutes() * 60

  @doc "Encrypts the just-created user id and validated workspace/profile intent."
  def sign(user_id, account_name, full_name)
      when is_binary(user_id) and is_binary(account_name) and
             (is_binary(full_name) or is_nil(full_name)),
      do: Phoenix.Token.encrypt(EmisarWeb.Endpoint, @salt, {user_id, account_name, full_name})

  @doc "A same-shaped handoff that names no user, for a neutral existing-email response."
  def decoy(account_name, full_name)
      when is_binary(account_name) and (is_binary(full_name) or is_nil(full_name)),
      do: sign(Ecto.UUID.generate(), account_name, full_name)

  @doc "Decrypts a handoff -> `{:ok, {user_id, account_name, full_name}} | {:error, reason}`."
  def verify(handoff) when is_binary(handoff),
    do: Phoenix.Token.decrypt(EmisarWeb.Endpoint, @salt, handoff, max_age: @max_age_seconds)

  def verify(_), do: {:error, :invalid}
end
