defmodule Emisar.AnalyticsTest do
  # async: false — flips the global `:mixpanel_enabled` app env, so it must
  # not run concurrently with other tests that touch analytics seams.
  use ExUnit.Case, async: false

  alias Emisar.Analytics

  setup do
    # Opt this test into emission: enabled, synchronous (test.exs), and
    # reporting the stub's payloads back to this process.
    Application.put_env(:emisar, :mixpanel_enabled, true)
    Application.put_env(:emisar, :analytics_test_pid, self())

    on_exit(fn ->
      Application.put_env(:emisar, :mixpanel_enabled, false)
      Application.delete_env(:emisar, :analytics_test_pid)
      Application.delete_env(:emisar, :mixpanel_groups_enabled)
    end)

    :ok
  end

  describe "track/4" do
    test "emits one event with distinct_id, time, an $insert_id, and the custom props" do
      Analytics.track("action_dispatched", "user-123", %{"risk" => "high", "source" => "operator"})

      assert_receive {:mixpanel_track, [event]}
      assert event["event"] == "action_dispatched"
      props = event["properties"]
      assert props["distinct_id"] == "user-123"
      assert props["risk"] == "high"
      assert props["source"] == "operator"
      assert is_integer(props["time"])
      assert is_binary(props["$insert_id"])
    end

    test "carries device_id/user_id/ip from opts for identity merge + geo" do
      Analytics.track("signed_in", "user-7", %{},
        device_id: "dev-1",
        user_id: "user-7",
        ip: "1.2.3.4"
      )

      assert_receive {:mixpanel_track, [event]}
      props = event["properties"]
      assert props["$device_id"] == "dev-1"
      assert props["$user_id"] == "user-7"
      assert props["ip"] == "1.2.3.4"
    end

    test "drops nil and blank properties, keeps false and 0" do
      Analytics.track("x", "id", %{"a" => nil, "b" => "", "c" => false, "d" => 0})

      assert_receive {:mixpanel_track, [event]}
      props = event["properties"]
      refute Map.has_key?(props, "a")
      refute Map.has_key?(props, "b")
      assert props["c"] == false
      assert props["d"] == 0
    end

    test "omits absent identity opts entirely" do
      Analytics.track("x", "id", %{})

      assert_receive {:mixpanel_track, [event]}
      props = event["properties"]
      refute Map.has_key?(props, "$device_id")
      refute Map.has_key?(props, "$user_id")
      refute Map.has_key?(props, "ip")
    end

    test "is a no-op when analytics is disabled" do
      Application.put_env(:emisar, :mixpanel_enabled, false)
      Analytics.track("x", "id", %{})
      refute_receive {:mixpanel_track, _}
    end
  end

  describe "set_people/3" do
    test "emits an engage $set with geo suppressed" do
      Analytics.set_people("user-9", %{"$email" => "a@b.co", "plan" => "team"})

      assert_receive {:mixpanel_engage, [update]}
      assert update["$distinct_id"] == "user-9"
      assert update["$ip"] == "0"
      assert update["$set"] == %{"$email" => "a@b.co", "plan" => "team"}
    end
  end

  describe "set_group/4" do
    test "is gated off by default" do
      Analytics.set_group("account_id", "acc-1", %{"name" => "Acme"})
      refute_receive {:mixpanel_groups, _}
    end

    test "emits when Group Analytics is enabled" do
      Application.put_env(:emisar, :mixpanel_groups_enabled, true)
      Analytics.set_group("account_id", "acc-1", %{"name" => "Acme"})

      assert_receive {:mixpanel_groups, [group]}
      assert group["$group_key"] == "account_id"
      assert group["$group_id"] == "acc-1"
      assert group["$set"] == %{"name" => "Acme"}
    end
  end
end
