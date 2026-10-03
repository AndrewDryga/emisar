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
      assert html =~ "Opening checkout"
      assert html =~ "Go to Billing"
      assert html =~ ~s(href="/app/billing")
      refute html =~ "pop-up"
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

    test "a signed return for this transaction pins both return links, without a session", %{
      conn: conn
    } do
      Emisar.Config.put_override(:emisar, :paddle_client_token, "live_tok_123")
      account_id = Ecto.UUID.generate()
      checkout = Emisar.Crypto.checkout_return(account_id, "txn_123")

      html =
        conn
        |> get(~p"/checkout", %{"_ptxn" => "txn_123", "emisar_return" => checkout})
        |> html_response(200)

      success_url = EmisarWeb.Endpoint.url() <> ~p"/app/checkout/success?#{[checkout: checkout]}"
      assert html =~ ~s(data-success-url="#{success_url}")
      assert html =~ ~s(href="/app/#{account_id}/settings/billing")
    end

    test "a tampered, expired, other-checkout or unsigned return gets only the neutral links (review revision 11)",
         %{conn: conn} do
      Emisar.Config.put_override(:emisar, :paddle_client_token, "live_tok_123")
      account_id = Ecto.UUID.generate()
      valid = Emisar.Crypto.checkout_return(account_id, "txn_123")

      expired =
        Phoenix.Token.sign(
          Application.fetch_env!(:emisar, :email_link_secret),
          "checkout return",
          {account_id, "txn_123"},
          signed_at: System.system_time(:second) - 25 * 60 * 60
        )

      for params <- [
            # Edited in transit: the signature no longer holds.
            %{"emisar_return" => tamper(valid)},
            %{"emisar_return" => expired},
            # Another checkout's valid return pasted onto this transaction.
            %{"emisar_return" => Emisar.Crypto.checkout_return(account_id, "txn_other")},
            # The plain account id older links carried is no longer read.
            %{"emisar_account_id" => account_id},
            %{"emisar_return" => ["bad"]},
            %{}
          ] do
        html =
          conn
          |> get(~p"/checkout", Map.put(params, "_ptxn", "txn_123"))
          |> html_response(200)

        assert html =~ ~s(data-success-url="#{EmisarWeb.Endpoint.url()}/app/checkout/success")
        assert html =~ ~s(href="/app/billing")
        refute html =~ account_id
      end
    end

    test "a link without its ?_ptxn= transaction renders the incomplete state, not the spinner",
         %{
           conn: conn
         } do
      # Paddle's checkout.url always carries the transaction; without it
      # Paddle.js has nothing to open and the old page spun forever.
      Emisar.Config.put_override(:emisar, :paddle_client_token, "live_tok_123")

      html = conn |> get(~p"/checkout") |> html_response(200)

      assert html =~ "This checkout link is incomplete"
      assert html =~ "Go to Billing"
      refute html =~ "Opening checkout"
      refute html =~ "paddle.js"
    end

    test "redirects to /pricing when no client token is configured", %{conn: conn} do
      Emisar.Config.put_override(:emisar, :paddle_client_token, nil)

      conn = get(conn, ~p"/checkout")

      assert redirected_to(conn) == "/pricing"
    end
  end

  describe "GET /app/checkout/success" do
    test "a valid return goes to that workspace's billing page, never claiming payment", %{
      conn: conn
    } do
      {conn, owner, account} = register_and_log_in(conn)
      checkout = Emisar.Crypto.checkout_return(account.id, "txn_123")

      conn = get(conn, ~p"/app/checkout/success?#{[checkout: checkout]}")

      assert redirected_to(conn) == ~p"/app/#{account.id}/settings/billing"
      flash = Phoenix.Flash.get(conn.assigns.flash, :info)
      assert flash =~ "once your payment and subscription are confirmed"
      refute flash =~ "Payment received"

      subject = Fixtures.Subjects.subject_for(owner)
      assert {:ok, %{plan: "free"}} = Emisar.Billing.billing_summary(account, subject)
    end

    test "a tampered, expired or missing return gets neutral guidance", %{conn: conn} do
      {conn, _owner, account} = register_and_log_in(conn)
      valid = Emisar.Crypto.checkout_return(account.id, "txn_123")

      expired =
        Phoenix.Token.sign(
          Application.fetch_env!(:emisar, :email_link_secret),
          "checkout return",
          {account.id, "txn_123"},
          signed_at: System.system_time(:second) - 25 * 60 * 60
        )

      for params <- [
            %{"checkout" => tamper(valid)},
            %{"checkout" => expired},
            %{"account_id_or_slug" => account.id},
            %{}
          ] do
        neutral = get(conn, ~p"/app/checkout/success", params)

        assert redirected_to(neutral) == ~p"/app/billing"

        assert Phoenix.Flash.get(neutral.assigns.flash, :info) ==
                 "Choose the workspace you upgraded to check its billing status."
      end
    end

    test "another workspace's valid return still needs that workspace's own session", %{
      conn: conn
    } do
      {conn, _owner, _account} = register_and_log_in(conn)
      {_other_owner, other, _subject} = Fixtures.Subjects.owner_subject()
      checkout = Emisar.Crypto.checkout_return(other.id, "txn_123")

      returned = get(conn, ~p"/app/checkout/success?#{[checkout: checkout]}")
      assert redirected_to(returned) == ~p"/app/#{other.id}/settings/billing"

      # The billing page authorizes on its own: this browser has no session there.
      billing = returned |> recycle() |> get(~p"/app/#{other.id}/settings/billing")
      assert redirected_to(billing) == ~p"/app/#{other}/sign_in"
    end

    test "an anonymous return goes to sign-in and keeps the exact return", %{conn: conn} do
      checkout = Emisar.Crypto.checkout_return(Ecto.UUID.generate(), "txn_123")
      path = ~p"/app/checkout/success?#{[checkout: checkout]}"

      conn = get(conn, path)

      assert redirected_to(conn) == ~p"/sign_in"
      assert get_session(conn, :user_return_to) == path
    end
  end

  # The signed return with its last character changed: the signature no longer holds.
  # Edit the first character: every bit of it is data. The last character of
  # base64url can carry ignored padding bits, so flipping its low bit may leave
  # the signature valid and make this test flaky.
  defp tamper(token) do
    {first, rest} = String.split_at(token, 1)
    if(first == "A", do: "B", else: "A") <> rest
  end
end
