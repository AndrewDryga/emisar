defmodule Emisar.AnalyticsTest do
  # async: false — flips the global `:mixpanel_enabled` app env, so it must
  # not run concurrently with other tests that touch analytics seams.
  use ExUnit.Case, async: false
  alias Emisar.Analytics

  @analytics_env_keys [:mixpanel_enabled, :analytics_test_pid, :mixpanel_groups_enabled]
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

  describe "track/4" do
    test "emits one event with distinct_id, time, an $insert_id, and the custom props" do
      Analytics.track("action_dispatched", "user-123", %{"risk" => "high", "source" => "operator"})

      assert_receive {:mixpanel_track, [event]}, 500
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

      assert_receive {:mixpanel_track, [event]}, 500
      props = event["properties"]
      assert props["$device_id"] == "dev-1"
      assert props["$user_id"] == "user-7"
      assert props["ip"] == "1.2.3.4"
    end

    test "drops nil and blank properties, keeps false and 0" do
      Analytics.track("x", "id", %{"a" => nil, "b" => "", "c" => false, "d" => 0})

      assert_receive {:mixpanel_track, [event]}, 500
      props = event["properties"]
      refute Map.has_key?(props, "a")
      refute Map.has_key?(props, "b")
      assert props["c"] == false
      assert props["d"] == 0
    end

    test "omits absent identity opts entirely" do
      Analytics.track("x", "id", %{})

      assert_receive {:mixpanel_track, [event]}, 500
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

      assert_receive {:mixpanel_engage, [update]}, 500
      assert update["$distinct_id"] == "user-9"
      assert update["$ip"] == "0"
      assert update["$set"] == %{"$email" => "a@b.co", "plan" => "team"}
    end

    test "compacts profile properties and preserves a supplied $set_once" do
      Analytics.set_people(
        "user-9",
        %{"plan" => "team", "empty" => ""},
        set_once: %{"created_at" => "2026-07-09", "empty" => nil}
      )

      assert_receive {:mixpanel_engage, [update]}, 500
      assert update["$set"] == %{"plan" => "team"}
      assert update["$set_once"] == %{"created_at" => "2026-07-09"}
    end
  end

  describe "set_group/3" do
    test "is gated off by default" do
      Analytics.set_group("account_id", "acc-1", %{"name" => "Acme"})
      refute_receive {:mixpanel_groups, _}
    end

    test "emits when Group Analytics is enabled" do
      Application.put_env(:emisar, :mixpanel_groups_enabled, true)
      Analytics.set_group("account_id", "acc-1", %{"name" => "Acme"})

      assert_receive {:mixpanel_groups, [group]}, 500
      assert group["$group_key"] == "account_id"
      assert group["$group_id"] == "acc-1"
      assert group["$set"] == %{"name" => "Acme"}
    end

    test "omits blank group properties" do
      Application.put_env(:emisar, :mixpanel_groups_enabled, true)
      Analytics.set_group("account_id", "acc-1", %{"name" => "Acme", "empty" => nil})

      assert_receive {:mixpanel_groups, [group]}, 500
      assert group["$set"] == %{"name" => "Acme"}
    end
  end
end
