defmodule EmisarWeb.SignInController do
  @moduledoc """
  The sign-in page (`/sign_in`): "which workspace?". Every sign-in targets one
  workspace, so the operator picks it here and lands on that workspace's own
  sign-in page (`/app/:slug/sign_in`), which offers its SSO and, unless it
  requires SSO, the emailed code. Returning browsers get their recent workspaces
  as one-click buttons (signed cookie), and anyone can type a workspace's
  address. A controller (not a LiveView) so it can read the recent-workspaces
  cookie off the conn. It stays open to a signed-in browser: it is also how one
  signs in to another workspace.
  """
  use EmisarWeb, :controller
  alias Emisar.Accounts
  alias EmisarWeb.RecentAccounts

  def new(conn, _params) do
    render(conn, :new, recent: RecentAccounts.list(conn), form: workspace_form(""), error: nil)
  end

  def create(conn, %{"workspace" => %{"slug" => slug}}) when is_binary(slug) do
    case Accounts.fetch_account_by_id_or_slug_including_disabled(String.trim(slug)) do
      {:ok, account} ->
        redirect(conn, to: ~p"/app/#{account}/sign_in")

      {:error, :not_found} ->
        render_not_found(conn, slug)
    end
  end

  def create(conn, _params), do: render_not_found(conn, "")

  defp render_not_found(conn, slug) do
    render(conn, :new,
      recent: RecentAccounts.list(conn),
      form: workspace_form(slug),
      error: "We couldn't find a workspace at that address. Check it or ask your administrator."
    )
  end

  defp workspace_form(slug), do: Phoenix.Component.to_form(%{"slug" => slug}, as: "workspace")
end
