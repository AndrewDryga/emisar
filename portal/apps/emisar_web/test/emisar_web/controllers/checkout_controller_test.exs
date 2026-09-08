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

    test "an origin UUID pins both return links without needing a session", %{conn: conn} do
      Emisar.Config.put_override(:emisar, :paddle_client_token, "live_tok_123")
      account_id = Ecto.UUID.generate()

      html =
        conn
        |> get(~p"/checkout?_ptxn=txn_123&emisar_account_id=#{account_id}")
        |> html_response(200)

      assert html =~
               ~s(data-success-url="#{EmisarWeb.Endpoint.url()}/app/#{account_id}/checkout/success")

      assert html =~ ~s(href="/app/#{account_id}/settings/billing")

      incomplete =
        conn
        |> get(~p"/checkout?emisar_account_id=#{account_id}")
        |> html_response(200)

      assert incomplete =~ ~s(href="/app/#{account_id}/settings/billing")
      refute incomplete =~ "paddle.js"
    end

    test "malformed origins cannot supply return paths", %{conn: conn} do
      Emisar.Config.put_override(:emisar, :paddle_client_token, "live_tok_123")

      for origin <- [
            "",
            "demo",
            "sixteen-raw-bytes",
            "https://evil.example/",
            "../other",
            ["bad"],
            %{"id" => "bad"}
          ] do
        html =
          conn
          |> get(~p"/checkout", %{"_ptxn" => "txn_123", "emisar_account_id" => origin})
          |> html_response(200)

        assert html =~ ~s(data-success-url="#{EmisarWeb.Endpoint.url()}/app/checkout/success")
        assert html =~ ~s(href="/app/billing")
        refute html =~ "evil.example"
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
    test "an old unscoped return gives neutral guidance, even with a spoofed path parameter", %{
      conn: conn
    } do
      {conn, user, account} = register_and_log_in(conn)

      conn = get(conn, ~p"/app/checkout/success?account_id_or_slug=#{account.id}")

      assert redirected_to(conn) == "/app/#{account.slug}/settings/billing"
      # Never claim money was received on a bare redirect — the webhook-backed
      # subscription on the billing page is the source of truth.
      flash = Phoenix.Flash.get(conn.assigns.flash, :info)
      assert flash == "Choose the workspace you upgraded to check its billing status."
      refute flash =~ "Payment received"

      subject = Fixtures.Subjects.subject_for(user, account)
      assert {:ok, %{plan: "free"}} = Emisar.Billing.billing_summary(account, subject)
    end

    test "an anonymous return bounces to sign-in", %{conn: conn} do
      conn = get(conn, ~p"/app/checkout/success")

      assert redirected_to(conn) =~ "/sign_in"
    end
  end

  describe "GET /app/:account_id_or_slug/checkout/success" do
    test "returns to the origin after another tab switches accounts and the origin is renamed", %{
      conn: conn
    } do
      {conn, user, origin} = register_and_log_in(conn)
      selected = Fixtures.Accounts.create_account()

      Fixtures.Memberships.create_membership(
        account_id: selected.id,
        user_id: user.id,
        role: "owner"
      )

      subject = Fixtures.Subjects.subject_for(user, origin)
      new_slug = Fixtures.Random.unique_slug()
      assert {:ok, renamed} = Emisar.Accounts.update_account(origin, %{slug: new_slug}, subject)

      conn =
        conn
        |> put_session(:current_account_id, selected.id)
        |> get(~p"/app/#{origin.id}/checkout/success")

      assert redirected_to(conn) == ~p"/app/#{renamed}/settings/billing"
      assert get_session(conn, :current_account_id) == origin.id

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "once your payment and subscription are confirmed"

      assert {:ok, %{plan: "free"}} = Emisar.Billing.billing_summary(renamed, subject)

      assert {:ok, %{plan: "free"}} =
               Emisar.Billing.billing_summary(
                 selected,
                 Fixtures.Subjects.subject_for(user, selected)
               )
    end

    test "an absent or foreign origin never falls back to the selected account", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn)
      foreign = Fixtures.Accounts.create_account()

      for origin_id <- [foreign.id, Ecto.UUID.generate()] do
        assert_error_sent 404, fn -> get(conn, ~p"/app/#{origin_id}/checkout/success") end
      end
    end

    test "a suspended origin membership never falls back to another active membership", %{
      conn: conn
    } do
      {conn, user, selected} = register_and_log_in(conn)
      origin = Fixtures.Accounts.create_account()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: origin.id,
          user_id: user.id,
          role: "owner"
        )

      Fixtures.Memberships.suspend_membership(membership)
      conn = put_session(conn, :current_account_id, selected.id)

      assert_error_sent 404, fn -> get(conn, ~p"/app/#{origin.id}/checkout/success") end
    end

    test "an anonymous return preserves the exact origin for sign-in", %{conn: conn} do
      origin_id = Ecto.UUID.generate()
      path = ~p"/app/#{origin_id}/checkout/success"
      conn = get(conn, path)

      assert redirected_to(conn) =~ "/sign_in"
      assert get_session(conn, :user_return_to) == path
    end
  end
end
