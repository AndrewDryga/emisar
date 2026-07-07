defmodule EmisarWeb.RegistrationHandoff do
  @moduledoc """
  The short-lived handoff from the signup LiveView to the magic-link controller.

  `UserSignUpLive` creates the user, signs that exact user id, then lets the
  browser submit the email form to `UserSessionController.magic_link_start`,
  which is the boundary that can set the signed magic cookie. The controller
  only marks a magic-link request as a registration when this handoff verifies
  and matches the user found by email, so a forged `registration=1` POST cannot
  turn an arbitrary unconfirmed account into a signup recovery flow.

  One seam wrapping `Phoenix.Token` (IL-19) so the handoff crypto has a single,
  testable review surface.
  """
  @salt "registration magic handoff"
  @max_age_seconds 120

  @doc "Signs the just-created `user_id` into an opaque registration handoff."
  def sign(user_id) when is_binary(user_id),
    do: Phoenix.Token.sign(EmisarWeb.Endpoint, @salt, user_id)

  @doc "Verifies a handoff -> `{:ok, user_id} | {:error, reason}`."
  def verify(handoff) when is_binary(handoff),
    do: Phoenix.Token.verify(EmisarWeb.Endpoint, @salt, handoff, max_age: @max_age_seconds)

  def verify(_), do: {:error, :invalid}
end
