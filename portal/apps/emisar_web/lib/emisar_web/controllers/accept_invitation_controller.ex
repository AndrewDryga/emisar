defmodule EmisarWeb.AcceptInvitationController do
  @moduledoc "Signed-in invitation acceptance commits before any socket retirement can lose the handoff."
  use EmisarWeb, :controller
  alias Emisar.{Accounts, Users}

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
