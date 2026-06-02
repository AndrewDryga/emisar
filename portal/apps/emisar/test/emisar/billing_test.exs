defmodule Emisar.BillingTest do
  use ExUnit.Case, async: true

  alias Emisar.Billing

  describe "plans/0" do
    test "has free, team, enterprise" do
      plans = Billing.plans()
      assert plans["free"].runners_limit == 3
      assert plans["team"].monthly_price_cents == 2000
      assert plans["enterprise"].runners_limit == :unlimited
    end
  end

  describe "headroom/2" do
    test ":ok when more than one slot free" do
      assert Billing.headroom(%{runner_count: 1, runner_limit: 3}, :runners) == :ok
    end

    test ":warning when exactly one slot free" do
      assert Billing.headroom(%{runner_count: 2, runner_limit: 3}, :runners) == :warning
    end

    test ":at_limit when used == limit" do
      assert Billing.headroom(%{runner_count: 3, runner_limit: 3}, :runners) == :at_limit
    end

    test ":at_limit also when used > limit (operator deleted plan-tier-gated rows)" do
      assert Billing.headroom(%{runner_count: 5, runner_limit: 3}, :runners) == :at_limit
    end

    test ":unlimited bypasses everything" do
      assert Billing.headroom(%{runner_count: 100, runner_limit: :unlimited}, :runners) ==
               :unlimited
    end

    test "members uses the member_count/limit fields" do
      assert Billing.headroom(%{member_count: 0, member_limit: 1}, :members) == :warning
      assert Billing.headroom(%{member_count: 1, member_limit: 1}, :members) == :at_limit

      assert Billing.headroom(%{member_count: 5, member_limit: :unlimited}, :members) ==
               :unlimited
    end
  end

  describe "paddle client stub" do
    setup do
      Application.put_env(:emisar, :paddle_client, Emisar.Billing.PaddleClient.Stub)
      :ok
    end

    test "create_customer returns a deterministic id for the same email" do
      {:ok, %{"id" => id1}} =
        Emisar.Billing.PaddleClient.create_customer(%{email: "a@example.com"})

      {:ok, %{"id" => id2}} =
        Emisar.Billing.PaddleClient.create_customer(%{email: "a@example.com"})

      assert id1 == id2
      assert String.starts_with?(id1, "ctm_stub_")
    end

    test "create_checkout_session returns a checkout URL" do
      {:ok, %{"url" => url}} =
        Emisar.Billing.PaddleClient.create_checkout_session(%{
          customer: "ctm_test",
          price_id: "pri_test"
        })

      assert String.starts_with?(url, "https://stub.paddle.test/checkout/")
    end

    test "construct_webhook_event parses JSON payloads" do
      payload = ~s({"event_type":"subscription.created","event_id":"evt_1"})

      {:ok, event} =
        Emisar.Billing.PaddleClient.construct_webhook_event(payload, "sig", "secret")

      assert event["event_type"] == "subscription.created"
    end
  end

  describe "extract_next_billed_at/1" do
    test "parses ISO8601 from next_billed_at" do
      iso = "2026-07-01T00:00:00Z"

      assert %DateTime{year: 2026, month: 7, day: 1} =
               Billing.extract_next_billed_at(%{"next_billed_at" => iso})
    end

    test "falls back to current_billing_period.ends_at" do
      iso = "2026-08-15T12:34:56Z"

      assert %DateTime{year: 2026, month: 8, day: 15} =
               Billing.extract_next_billed_at(%{
                 "current_billing_period" => %{"ends_at" => iso}
               })
    end

    test "nil when neither field present" do
      assert Billing.extract_next_billed_at(%{}) == nil
    end
  end
end
