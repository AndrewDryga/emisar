defmodule EmisarWeb.CheckoutController do
  @moduledoc """
  The Paddle checkout surface.

  `show` is the account's default payment link: a minimal page whose only job
  is to run Paddle.js — Paddle Checkout has no hosted page, so the
  `checkout.url` Paddle mints for a transaction is THIS page plus a `?_ptxn=`
  parameter, and Paddle.js auto-opens the overlay for that transaction once
  initialized. Noindex (a utility page, not marketing), and CSP is widened
  per-request to Paddle's origins only here.

  `success` is where the overlay redirects after payment: it resolves the
  session's current account (the slug isn't known when the page renders) and
  lands the operator back on that account's billing page.
  """
  use EmisarWeb, :controller

  plug :put_layout, html: {EmisarWeb.Layouts, :app}

  def show(conn, _params) do
    case Application.get_env(:emisar, :paddle_client_token) do
      nil ->
        # No client token (stub billing / self-host) — nothing to initialize.
        redirect(conn, to: "/pricing")

      token ->
        conn
        |> assign(:page_title, "Checkout")
        |> assign(:paddle_client_token, token)
        |> assign(:paddle_sandbox?, String.starts_with?(token, "test_"))
        |> assign(:success_url, url(~p"/app/checkout/success"))
        |> assign(:csp_extra, paddle_csp())
        |> render(:show)
    end
  end

  def success(conn, _params) do
    account = conn.assigns.current_account

    conn
    |> put_flash(:info, "Payment received — your subscription updates in a few seconds.")
    |> redirect(to: ~p"/app/#{account}/settings/billing")
  end

  # Paddle.js loads from cdn.paddle.com and opens the checkout overlay in an
  # iframe on buy.paddle.com (sandbox-buy in sandbox); its price/transaction
  # reads hit *.paddle.com service hosts. Scoped to this page only.
  defp paddle_csp do
    %{
      "script-src" => ["https://cdn.paddle.com"],
      "connect-src" => ["https://*.paddle.com"],
      "frame-src" => ["'self'", "https://buy.paddle.com", "https://sandbox-buy.paddle.com"]
    }
  end
end
