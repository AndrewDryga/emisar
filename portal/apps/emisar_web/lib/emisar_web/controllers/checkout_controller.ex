defmodule EmisarWeb.CheckoutController do
  @moduledoc """
  The Paddle checkout surface.

  `show` is the account's default payment link: a minimal page whose only job
  is to run Paddle.js — Paddle Checkout has no hosted page, so the
  `checkout.url` Paddle mints for a transaction is THIS page plus a `?_ptxn=`
  parameter, and Paddle.js auto-opens the overlay for that transaction once
  initialized. Noindex (a utility page, not marketing), and CSP is widened
  per-request to Paddle's origins only here.

  Every checkout URL Emisar hands out carries signed return state over the
  workspace and the transaction it pays (`Billing.verify_checkout_return/1`).
  `show` builds the return from it only when it verifies and names this
  transaction, and `success` verifies it again before routing to that
  workspace's billing page, whose own session authorizes it. A URL without it,
  or with an edited, foreign or expired one, gets a neutral return — never a
  payment confirmation for a workspace the URL merely names.
  """
  use EmisarWeb, :controller
  alias Emisar.Billing

  plug :put_layout, html: {EmisarWeb.Layouts, :app}

  def show(conn, params) do
    token = Emisar.Config.get_env(:emisar, :paddle_client_token)
    conn = assign_return_paths(conn, params["emisar_return"], params["_ptxn"])

    cond do
      # No client token (stub billing / self-host) — nothing to initialize.
      is_nil(token) ->
        redirect(conn, to: "/pricing")

      # Paddle's checkout.url always carries ?_ptxn=; without it Paddle.js has
      # no transaction to open and the "Opening secure checkout…" spinner would
      # spin forever. Render the honest dead-link state instead.
      missing_transaction?(params["_ptxn"]) ->
        conn
        |> assign(:page_title, "Incomplete checkout link")
        |> render(:expired)

      true ->
        conn
        |> assign(:page_title, "Checkout")
        |> assign(:paddle_client_token, token)
        |> assign(:paddle_sandbox?, String.starts_with?(token, "test_"))
        |> assign(:csp_extra, paddle_csp())
        |> render(:show)
    end
  end

  defp missing_transaction?(ptxn), do: not is_binary(ptxn) or String.trim(ptxn) == ""

  defp assign_return_paths(conn, checkout_return, transaction_id) do
    case Billing.verify_checkout_return(checkout_return) do
      {:ok, %{account_id: account_id, transaction_id: ^transaction_id}} ->
        conn
        |> assign(:success_url, url(~p"/app/checkout/success?#{[checkout: checkout_return]}"))
        |> assign(:billing_url, ~p"/app/#{account_id}/settings/billing")

      _missing_or_not_this_checkout ->
        conn
        |> assign(:success_url, url(~p"/app/checkout/success"))
        |> assign(:billing_url, ~p"/app/billing")
    end
  end

  def success(conn, params) do
    case Billing.verify_checkout_return(params["checkout"]) do
      {:ok, %{account_id: account_id}} ->
        conn
        |> put_flash(
          :info,
          "Your plan will update here once your payment and subscription are confirmed."
        )
        |> redirect(to: ~p"/app/#{account_id}/settings/billing")

      {:error, :invalid} ->
        conn
        |> put_flash(:info, "Choose the workspace you upgraded to check its billing status.")
        |> redirect(to: ~p"/app/billing")
    end
  end

  # Paddle.js loads its script + loader stylesheet from cdn.paddle.com, opens
  # the checkout overlay in an iframe on buy.paddle.com (sandbox-buy in
  # sandbox), reads prices/transactions from *.paddle.com service hosts, and
  # pulls Paddle Retain (ProfitWell — a Paddle company, part of the
  # merchant-of-record stack; disclosed under Paddle on /trust + /dpa).
  # All of it scoped to this page only.
  defp paddle_csp do
    %{
      "script-src" => ["https://cdn.paddle.com", "https://public.profitwell.com"],
      "style-src" => ["https://cdn.paddle.com"],
      "connect-src" => ["https://*.paddle.com", "https://*.profitwell.com"],
      "frame-src" => ["'self'", "https://buy.paddle.com", "https://sandbox-buy.paddle.com"]
    }
  end
end
