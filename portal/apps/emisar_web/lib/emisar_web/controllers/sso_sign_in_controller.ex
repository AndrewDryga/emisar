defmodule EmisarWeb.SSOSignInController do
  @moduledoc """
  The single-sign-on landing page (`/sign_in/sso`): "which team?". It does NOT
  guess by email domain anymore — the operator picks their team, then lands on
  that team's branded sign-in page (`/app/:slug/sign_in`). Returning browsers get
  their recent teams as one-click buttons (signed cookie), and anyone can type a
  team's address. A controller (not a LiveView) so it can read the recent-accounts
  cookie off the conn.
  """
  use EmisarWeb, :controller
  alias Emisar.Accounts
  alias EmisarWeb.RecentAccounts

  def new(conn, _params) do
    render(conn, :new, recent: RecentAccounts.list(conn), form: team_form(""))
  end

  def create(conn, %{"team" => %{"slug" => slug}}) when is_binary(slug) do
    case Accounts.fetch_account_by_id_or_slug(String.trim(slug)) do
      {:ok, account} ->
        redirect(conn, to: ~p"/app/#{account}/sign_in")

      {:error, :not_found} ->
        render_not_found(conn, slug)
    end
  end

  def create(conn, _params), do: render_not_found(conn, "")

  defp render_not_found(conn, slug) do
    conn
    |> put_flash(:error, "We couldn't find a team at that address. Check it and try again.")
    |> render(:new, recent: RecentAccounts.list(conn), form: team_form(slug))
  end

  defp team_form(slug), do: Phoenix.Component.to_form(%{"slug" => slug}, as: "team")
end
