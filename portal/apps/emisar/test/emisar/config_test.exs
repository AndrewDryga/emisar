defmodule Emisar.ConfigTest do
  # async: true is the whole point — overrides live in the test's own process,
  # so concurrent tests can never clobber each other the way Application.put_env does.
  use ExUnit.Case, async: true

  describe "get_env/3" do
    test "falls back to the Application default when no override is set" do
      assert Emisar.Config.get_env(:emisar, :unset_probe_key, :the_default) == :the_default
    end

    test "a per-process override wins over the Application env" do
      Emisar.Config.put_override(:emisar, :probe_key, :overridden)
      assert Emisar.Config.get_env(:emisar, :probe_key, :the_default) == :overridden
    end

    test "a false override still wins (tagged cascade, not `override || app_env`)" do
      Emisar.Config.put_override(:emisar, :probe_flag, false)
      assert Emisar.Config.get_env(:emisar, :probe_flag, true) == false
    end

    test "resolves an override across $callers (async task / LiveView process)" do
      Emisar.Config.put_override(:emisar, :probe_key, :from_owner)
      task = Task.async(fn -> Emisar.Config.get_env(:emisar, :probe_key, :default) end)
      assert Task.await(task) == :from_owner
    end

    test "resolves an override via :last_caller_pid (browser/socket bridge)" do
      owner = self()
      reference = make_ref()
      Emisar.Config.put_override(:emisar, :probe_key, :from_owner)

      # A bare spawn inherits neither $callers nor $ancestors, so :last_caller_pid
      # (planted by EmisarWeb.Sandbox from the sandbox user-agent) is the only path.
      spawn(fn ->
        Process.put(:last_caller_pid, owner)
        send(owner, {reference, Emisar.Config.get_env(:emisar, :probe_key, :default)})
      end)

      assert_receive {^reference, :from_owner}
    end
  end

  describe "fetch_env!/2" do
    test "prefers a per-process override" do
      Emisar.Config.put_override(:emisar, :probe_required, "overridden")
      assert Emisar.Config.fetch_env!(:emisar, :probe_required) == "overridden"
    end

    test "raises when neither an override nor Application env is set" do
      assert_raise ArgumentError, fn ->
        Emisar.Config.fetch_env!(:emisar, :definitely_missing_probe)
      end
    end
  end
end
