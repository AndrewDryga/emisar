defmodule EmisarWeb.AccountSwitchController do
  @moduledoc """
  Single endpoint for switching the user's active account. Validates the
  user has a non-suspended membership on the requested account, pins
  the choice in the Plug session via `UserAuth.switch_account/2`, and
  redirects to `/app`. The next request reads the new session value
  through `assign_current_account/1`, so every LiveView remounts under
  the new tenant.
  """
  use EmisarWeb, :controller
  alias Emisar.Accounts
  alias EmisarWeb.UserAuth

  def switch(conn, %{"account_id" => account_id}) when is_binary(account_id) do
    case UserAuth.switch_account(conn, account_id) do
      {:ok, conn, membership} ->
        {:ok, _} = Accounts.record_account_switched(membership)
        redirect(conn, to: ~p"/app/#{membership.account}")

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "You aren't a member of that account.")
        |> redirect(to: ~p"/app")
    end
  end

  def switch(conn, _params) do
    conn
    |> put_flash(:error, "Missing account id.")
    |> redirect(to: ~p"/app")
  end
end
