defmodule EmisarWeb.CheckoutControllerTest do
  @moduledoc """
  The Paddle default payment link (/checkout) and its post-payment return.
  The page's only job is to run Paddle.js so the ?_ptxn= overlay opens —
  with a page-scoped CSP widened to Paddle's origins and never indexed.
  """
  use EmisarWeb.ConnCase, async: true

  setup do
    prev = Application.get_env(:emisar, :paddle_client_token)

    on_exit(fn ->
      if prev do
        Application.put_env(:emisar, :paddle_client_token, prev)
      else
        Application.delete_env(:emisar, :paddle_client_token)
      end
    end)

    :ok
  end

  describe "GET /checkout" do
    test "renders Paddle.js with the client token and a page-scoped CSP", %{conn: conn} do
      Application.put_env(:emisar, :paddle_client_token, "live_tok_123")

      conn = get(conn, ~p"/checkout")
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
    end

    test "a test_ client token initializes the sandbox environment", %{conn: conn} do
      Application.put_env(:emisar, :paddle_client_token, "test_tok_123")

      html = conn |> get(~p"/checkout") |> html_response(200)

      assert html =~ ~s(data-sandbox="true")
    end

    test "redirects to /pricing when no client token is configured", %{conn: conn} do
      Application.delete_env(:emisar, :paddle_client_token)

      conn = get(conn, ~p"/checkout")

      assert redirected_to(conn) == "/pricing"
    end
  end

  describe "GET /app/checkout/success" do
    test "lands the operator on their account's billing page with a flash", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)

      conn = get(conn, ~p"/app/checkout/success")

      assert redirected_to(conn) == "/app/#{account.slug}/settings/billing"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Payment received"
    end

    test "an anonymous return bounces to sign-in", %{conn: conn} do
      conn = get(conn, ~p"/app/checkout/success")

      assert redirected_to(conn) =~ "/sign_in"
    end
  end
end
