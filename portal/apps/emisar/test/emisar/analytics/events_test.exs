defmodule Emisar.Analytics.EventsTest do
  use ExUnit.Case, async: true
  alias Emisar.Analytics.Events
  alias Emisar.Billing.Subscription

  setup do
    Emisar.Config.put_override(:emisar, :mixpanel_enabled, true)
    Emisar.Config.put_override(:emisar, :analytics_test_pid, self())
    :ok
  end

  test "subscription_changed/1 attributes to the account with plan + status" do
    Events.subscription_changed(%Subscription{
      account_id: "acc-1",
      plan: "team",
      status: "active"
    })

    assert_receive {:mixpanel_track,
                    [%{"event" => "subscription_changed", "properties" => props}]},
                   500

    assert props["distinct_id"] == "account:acc-1"
    assert props["plan"] == "team"
    assert props["status"] == "active"
    assert props["account_id"] == "acc-1"
  end

  test "subscription_changed/1 updates the account group when group analytics is enabled" do
    Emisar.Config.put_override(:emisar, :mixpanel_groups_enabled, true)

    Events.subscription_changed(%Subscription{
      account_id: "acc-1",
      plan: "team",
      status: "active"
    })

    assert_receive {:mixpanel_groups, [group]}, 500
    assert group["$group_key"] == "account_id"
    assert group["$group_id"] == "acc-1"
    assert group["$set"] == %{"plan" => "team", "status" => "active"}
  end
end
