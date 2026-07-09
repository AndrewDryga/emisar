defmodule Emisar.Analytics.EventsTest do
  # async: false — flips the global `:mixpanel_enabled` app env.
  use ExUnit.Case, async: false
  alias Emisar.Analytics.Events
  alias Emisar.Billing.Subscription

  @analytics_env_keys [:mixpanel_enabled, :mixpanel_groups_enabled, :analytics_test_pid]
  @unset :unset

  setup do
    original = Map.new(@analytics_env_keys, &{&1, Application.get_env(:emisar, &1, @unset)})

    Application.put_env(:emisar, :mixpanel_enabled, true)
    Application.put_env(:emisar, :analytics_test_pid, self())

    on_exit(fn ->
      Enum.each(original, fn
        {key, @unset} -> Application.delete_env(:emisar, key)
        {key, value} -> Application.put_env(:emisar, key, value)
      end)
    end)

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
    Application.put_env(:emisar, :mixpanel_groups_enabled, true)

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
