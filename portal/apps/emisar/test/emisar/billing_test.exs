defmodule Emisar.BillingTest do
  use ExUnit.Case, async: true

  alias Emisar.Billing

  describe "plans/0" do
    test "has free, team, enterprise" do
      plans = Billing.plans()
      assert plans["free"].agents_limit == 3
      assert plans["team"].monthly_price_cents == 2000
      assert plans["enterprise"].agents_limit == :unlimited
    end
  end

  describe "stripe client stub" do
    setup do
      Application.put_env(:emisar, :stripe_client, Emisar.Billing.StripeClient.Stub)
      :ok
    end

    test "create_customer returns a deterministic id for the same email" do
      {:ok, %{"id" => id1}} =
        Emisar.Billing.StripeClient.create_customer(%{email: "a@example.com"})

      {:ok, %{"id" => id2}} =
        Emisar.Billing.StripeClient.create_customer(%{email: "a@example.com"})

      assert id1 == id2
      assert String.starts_with?(id1, "cus_stub_")
    end

    test "create_checkout_session returns a checkout URL" do
      {:ok, %{"url" => url}} =
        Emisar.Billing.StripeClient.create_checkout_session(%{
          customer: "cus_test",
          price_id: "price_test"
        })

      assert String.starts_with?(url, "https://stub.stripe.test/checkout/")
    end

    test "construct_webhook_event parses JSON payloads" do
      payload = ~s({"type":"customer.subscription.created","id":"evt_1"})
      {:ok, event} = Emisar.Billing.StripeClient.construct_webhook_event(payload, "sig", "secret")
      assert event["type"] == "customer.subscription.created"
    end
  end
end
