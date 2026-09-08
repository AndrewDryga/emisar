defmodule EmisarWeb.CheckoutController do
  @moduledoc """
  The Paddle checkout surface.

  `show` is the account's default payment link: a minimal page whose only job
  is to run Paddle.js — Paddle Checkout has no hosted page, so the
  `checkout.url` Paddle mints for a transaction is THIS page plus a `?_ptxn=`
  parameter, and Paddle.js auto-opens the overlay for that transaction once
  initialized. Noindex (a utility page, not marketing), and CSP is widened
  per-request to Paddle's origins only here.

  `success` returns to the originating account by immutable UUID, independently
  of the session's current account. Authentication authorizes the URL account.
  Older links without an origin use a neutral return, never payment confirmation.
  """
  use EmisarWeb, :controller

  plug :put_layout, html: {EmisarWeb.Layouts, :app}

  def show(conn, params) do
    token = Emisar.Config.get_env(:emisar, :paddle_client_token)
    conn = assign_return_paths(conn, params["emisar_account_id"])

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

  defp assign_return_paths(conn, origin) when is_binary(origin) and byte_size(origin) == 36 do
    case Ecto.UUID.cast(origin) do
      {:ok, account_id} ->
        conn
        |> assign(:success_url, url(~p"/app/#{account_id}/checkout/success"))
        |> assign(:billing_url, ~p"/app/#{account_id}/settings/billing")

      :error ->
        assign_return_paths(conn, nil)
    end
  end

  defp assign_return_paths(conn, _origin) do
    conn
    |> assign(:success_url, url(~p"/app/checkout/success"))
    |> assign(:billing_url, ~p"/app/billing")
  end

  def success(conn, _params) do
    account = conn.assigns.current_account

    conn
    |> put_flash(:info, return_message(conn.path_params))
    |> redirect(to: ~p"/app/#{account}/settings/billing")
  end

  defp return_message(%{"account_id_or_slug" => _account_ref}) do
    "Your plan will update here once your payment and subscription are confirmed."
  end

  defp return_message(_params) do
    "Choose the workspace you upgraded to check its billing status."
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
