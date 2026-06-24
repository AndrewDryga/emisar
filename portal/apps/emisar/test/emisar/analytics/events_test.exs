defmodule Emisar.Analytics.EventsTest do
  # async: false — flips the global `:mixpanel_enabled` app env.
  use ExUnit.Case, async: false

  alias Emisar.Analytics.Events
  alias Emisar.Billing.Subscription

  setup do
    Application.put_env(:emisar, :mixpanel_enabled, true)
    Application.put_env(:emisar, :analytics_test_pid, self())

    on_exit(fn ->
      Application.put_env(:emisar, :mixpanel_enabled, false)
      Application.delete_env(:emisar, :analytics_test_pid)
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
                    [%{"event" => "subscription_changed", "properties" => props}]}

    assert props["distinct_id"] == "account:acc-1"
    assert props["plan"] == "team"
    assert props["status"] == "active"
    assert props["account_id"] == "acc-1"
  end
end
