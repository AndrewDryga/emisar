defmodule EmisarWeb.UnsubscribeController do
  @moduledoc """
  Unauthenticated unsubscribe for the monthly account-health report. The
  emailed `List-Unsubscribe` link carries a signed, account-scoped token
  (`Emisar.Crypto.monthly_report_unsubscribe_token/1`) — the token IS the
  authorization, so no session is required.

  `GET` renders a confirmation page (read-only, so an email client's link
  prefetch can't unsubscribe anyone); `POST` performs the opt-out — reached
  either from that page's button or, for RFC 8058 one-click, directly by the
  mail provider. Both are rate-limited by IP.
  """
  use EmisarWeb, :controller
  alias Emisar.Accounts

  plug :put_layout, false
  plug EmisarWeb.Plugs.RateLimit, bucket: "unsubscribe", limit: 60, window_ms: 3_600_000, by: :ip

  def show(conn, %{"token" => token}) do
    case Accounts.fetch_account_for_report_unsubscribe(token) do
      {:ok, account} ->
        render(conn, :show, account_name: account.name, token: token, page_title: "Unsubscribe")

      {:error, :invalid} ->
        conn |> put_status(:not_found) |> render(:invalid, page_title: "Unsubscribe")
    end
  end

  def create(conn, %{"token" => token}) do
    case Accounts.unsubscribe_from_monthly_report(token) do
      {:ok, account} ->
        render(conn, :done, account_name: account.name, page_title: "Unsubscribed")

      {:error, _reason} ->
        conn |> put_status(:not_found) |> render(:invalid, page_title: "Unsubscribe")
    end
  end
end
