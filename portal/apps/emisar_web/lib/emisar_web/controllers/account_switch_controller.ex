defmodule EmisarWeb.AccountSwitchController do
  @moduledoc """
  Single endpoint for switching the user's active account.
  `Accounts.switch_account/2` validates the membership and records the switch;
  this controller pins the returned account in the Plug session via
  `UserAuth.switch_account/2` and redirects to it. The next request reads the
  new session value through `assign_current_account/1`, so every LiveView
  remounts under the new tenant.
  """
  use EmisarWeb, :controller
  alias Emisar.Accounts
  alias EmisarWeb.{BillingIntent, UserAuth}

  def switch(conn, %{"account_id" => account_id} = params) when is_binary(account_id) do
    case Accounts.switch_account(account_id, conn.assigns.current_subject) do
      {:ok, membership} ->
        continue_after_switch(conn, membership, params["billing_intent"])

      {:error, _reason} ->
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

  defp continue_after_switch(conn, membership, token) do
    case BillingIntent.verify(token) do
      {:ok, _intent} ->
        conn
        |> delete_session(:billing_intent)
        |> UserAuth.switch_account(membership)
        |> redirect(to: ~p"/app/#{membership.account}/settings/billing?billing_intent=#{token}")

      {:error, :invalid} ->
        conn
        |> delete_session(:billing_intent)
        |> UserAuth.switch_account(membership)
        |> redirect(to: ~p"/app/#{membership.account}")
    end
  end
end
