defmodule EmisarWeb.CheckoutControllerTest do
  @moduledoc """
  The Paddle default payment link (/checkout) and its post-payment return.
  The page's only job is to run Paddle.js so the ?_ptxn= overlay opens —
  with a page-scoped CSP widened to Paddle's origins and never indexed.
  """
  use EmisarWeb.ConnCase, async: true

  describe "GET /checkout" do
    test "renders Paddle.js with the client token and a page-scoped CSP", %{conn: conn} do
      Emisar.Config.put_override(:emisar, :paddle_client_token, "live_tok_123")

      conn = get(conn, ~p"/checkout?_ptxn=txn_123")
      html = html_response(conn, 200)

      assert html =~ "https://cdn.paddle.com/paddle/v2/paddle.js"
      assert html =~ ~s(data-token="live_tok_123")
      assert html =~ ~s(data-sandbox="false")
      assert html =~ "Paddle.Initialize"
      # Utility page — never indexed.
      assert html =~ ~s(name="robots" content="noindex)

      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "https://cdn.paddle.com"
      assert csp =~ "frame-src 'self' https://buy.paddle.com https://sandbox-buy.paddle.com"
      # The extra source WIDENS script-src (a duplicate directive would be
      # ignored by browsers, silently breaking Paddle.js).
      assert csp =~ ~r/script-src 'self' 'nonce-[^']+' https:\/\/cdn\.paddle\.com/
      # Paddle's loader stylesheet + Paddle Retain (ProfitWell — a Paddle
      # service, disclosed under Paddle on /trust + /dpa), checkout page only.
      assert csp =~ "style-src 'self' 'unsafe-inline' https://cdn.paddle.com"
      assert csp =~ "https://public.profitwell.com"
      assert csp =~ "https://*.profitwell.com"
    end

    test "a test_ client token initializes the sandbox environment", %{conn: conn} do
      Emisar.Config.put_override(:emisar, :paddle_client_token, "test_tok_123")

      html = conn |> get(~p"/checkout?_ptxn=txn_123") |> html_response(200)

      assert html =~ ~s(data-sandbox="true")
    end

    test "a link without its ?_ptxn= transaction renders the expired state, not the spinner", %{
      conn: conn
    } do
      # Paddle's checkout.url always carries the transaction; without it
      # Paddle.js has nothing to open and the old page spun forever.
      Emisar.Config.put_override(:emisar, :paddle_client_token, "live_tok_123")

      html = conn |> get(~p"/checkout") |> html_response(200)

      assert html =~ "This checkout link has expired"
      assert html =~ "Back to your console"
      refute html =~ "Opening secure checkout"
      refute html =~ "paddle.js"
    end

    test "redirects to /pricing when no client token is configured", %{conn: conn} do
      Emisar.Config.put_override(:emisar, :paddle_client_token, nil)

      conn = get(conn, ~p"/checkout")

      assert redirected_to(conn) == "/pricing"
    end
  end

  describe "GET /app/checkout/success" do
    test "lands the operator on their account's billing page with a flash", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      conn = get(conn, ~p"/app/checkout/success")

      assert redirected_to(conn) == "/app/#{account.slug}/settings/billing"
      # Never claim money was received on a bare redirect — the webhook-backed
      # subscription on the billing page is the source of truth.
      flash = Phoenix.Flash.get(conn.assigns.flash, :info)
      assert flash =~ "finishing your checkout"
      refute flash =~ "Payment received"
    end

    test "an anonymous return bounces to sign-in", %{conn: conn} do
      conn = get(conn, ~p"/app/checkout/success")

      assert redirected_to(conn) =~ "/sign_in"
    end
  end
end
