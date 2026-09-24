defmodule EmisarWeb.MemberLinkHandoff do
  @moduledoc """
  The short-lived handoff from a member-only workspace page to the email
  sign-in that links a personal login.

  A Member without a personal login signs in only through its workspace SSO
  identity. Profile and the required-MFA page sign this handoff for the exact
  account, Member, SSO identity and browser session (the donor) their Subject
  acts through, and the browser posts it with an email address to
  `UserSessionController.magic_link_start`. The controller accepts it only from
  that same member-only session and copies it onto the exact server-side magic
  factor. The final link transaction locks the donor by the presented session
  cookie and rechecks every named fact, so the handoff itself grants nothing.

  Signed, not encrypted: it names only the caller's own workspace ids. It is
  signed when the page mounts, so it outlives an idle page for an hour. One
  seam wrapping `Phoenix.Token` (IL-19) keeps that crypto testable in one place.
  """
  alias Emisar.Accounts
  alias Emisar.Auth.Subject

  @salt "member link handoff"
  @max_age_seconds 60 * 60

  @doc "Signs the link intent of a member-only Subject; nil for any other caller."
  def sign(%Subject{
        actor: %Accounts.Membership{user_id: nil},
        account: %{id: account_id},
        membership_id: membership_id,
        user_identity_id: identity_id,
        session_token_id: donor_token_id
      })
      when is_binary(account_id) and is_binary(membership_id) and is_binary(identity_id) and
             is_binary(donor_token_id) do
    Phoenix.Token.sign(
      EmisarWeb.Endpoint,
      @salt,
      {account_id, membership_id, identity_id, donor_token_id}
    )
  end

  def sign(_subject), do: nil

  @doc """
  Verifies a handoff -> `{:ok, {account_id, membership_id, identity_id,
  donor_token_id}} | {:error, reason}`.
  """
  def verify(handoff) when is_binary(handoff),
    do: Phoenix.Token.verify(EmisarWeb.Endpoint, @salt, handoff, max_age: @max_age_seconds)

  def verify(_), do: {:error, :invalid}
end
