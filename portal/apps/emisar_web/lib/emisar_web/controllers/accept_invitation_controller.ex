defmodule EmisarWeb.AcceptInvitationController do
  @moduledoc "Signed-in invitation acceptance commits before any socket retirement can lose the handoff."
  use EmisarWeb, :controller
  alias Emisar.{Accounts, Users}
  alias EmisarWeb.AcceptInvitationLive

  # Only the personal login that owns the invited address can accept here; the
  # domain compares the addresses, never this page's rendered state.
  def create(conn, %{"token" => token}) do
    with %Users.User{} = user <- conn.assigns.current_user,
         {:ok, membership} <- Accounts.fetch_invitation_by_token(token),
         {:ok, _membership} <- Accounts.mark_invitation_accepted(membership, token, user) do
      # Acceptance never adds authority to an old browser. Recovery preserves
      # its surviving grants until the user explicitly chooses to sign out.
      conn
      |> put_flash(:info, "Invitation accepted. Sign in again to access this workspace.")
      |> redirect(to: ~p"/session/recover")
    else
      {:error, :already_member} ->
        conn
        |> put_flash(:error, AcceptInvitationLive.already_member_message())
        |> redirect(to: ~p"/accept_invitation/#{token}")

      _error ->
        conn
        |> put_flash(
          :error,
          "Could not accept the invitation. Check the invitation and try again."
        )
        |> redirect(to: ~p"/accept_invitation/#{token}")
    end
  end
end
