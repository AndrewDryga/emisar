defmodule EmisarWeb.RunnerSocketDrainTest do
  @moduledoc """
  The graceful-shutdown coordinator. Two things are load-bearing:
  the process traps exits (without it `terminate/2` never runs on
  SIGTERM), and terminate broadcasts on the exact topic the runner
  sockets subscribe to.
  """
  use ExUnit.Case, async: true
  alias EmisarWeb.RunnerSocketDrain

  test "the supervised process traps exits so terminate/2 fires" do
    pid = Process.whereis(RunnerSocketDrain)
    assert is_pid(pid)
    assert Process.info(pid, :trap_exit) == {:trap_exit, true}
  end

  test "terminate broadcasts :runner_socket_drain on the shared topic" do
    :ok = Phoenix.PubSub.subscribe(Emisar.PubSub.Server, RunnerSocketDrain.drain_topic())

    # Direct call — the drain window sleep makes this take ~2s, which is
    # the documented flush window, not a test smell.
    assert RunnerSocketDrain.terminate(:shutdown, %{}) == :ok

    assert_receive :runner_socket_drain, 500
  end

  test "terminate drains this node's subscribers only, never the cluster adapter" do
    :ok = Phoenix.PubSub.subscribe(Emisar.PubSub.Server, RunnerSocketDrain.drain_topic())

    # The PG2 adapter's broadcast/4 is what fans a message out to other
    # nodes; the adapter runs in the caller, so tracing this process sees it.
    relay = spawn_link(&relay/0)
    send(relay, {:forward_to, self()})
    cluster_broadcast = {Phoenix.PubSub.PG2, :broadcast, 4}
    {:module, Phoenix.PubSub.PG2} = Code.ensure_loaded(Phoenix.PubSub.PG2)
    1 = :erlang.trace_pattern(cluster_broadcast, true, [:global])
    1 = :erlang.trace(self(), true, [:call, {:tracer, relay}])
    on_exit(fn -> :erlang.trace_pattern(cluster_broadcast, false, [:global]) end)

    # Sanity: a cluster broadcast is visible to the trace, so the refute
    # below cannot pass vacuously.
    :ok = Emisar.PubSub.broadcast("trace_probe", :probe)
    assert_receive {:trace, _, :call, {Phoenix.PubSub.PG2, :broadcast, [_ | _]}}, 500

    assert RunnerSocketDrain.terminate(:shutdown, %{}) == :ok

    assert_received :runner_socket_drain
    refute_received {:trace, _, :call, {Phoenix.PubSub.PG2, :broadcast, [_ | _]}}
  end

  # A process cannot deliver its own trace messages to itself, so a relay
  # process receives them and forwards to the test.
  defp relay do
    receive do
      {:forward_to, pid} -> relay(pid)
    end
  end

  defp relay(pid) do
    receive do
      msg -> send(pid, msg)
    end

    relay(pid)
  end
end
