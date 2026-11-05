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

  describe "two connected nodes" do
    setup do
      # Distribution is needed only here; epmd may not be running yet.
      System.cmd("epmd", ["-daemon"])

      unless Node.alive?() do
        {:ok, _} =
          Node.start(:"drain_test@127.0.0.1", :longnames)
      end

      args =
        Enum.flat_map(:code.get_path(), &[~c"-pa", &1]) ++
          [~c"-setcookie", Atom.to_charlist(Node.get_cookie())]

      {:ok, peer, node} =
        :peer.start_link(%{
          name: :drain_peer,
          host: ~c"127.0.0.1",
          longnames: true,
          args: args
        })

      on_exit(fn -> catch_exit(:peer.stop(peer)) end)

      # The test module only exists in this VM, so the peer runs evaluated
      # code. The PubSub must outlive the call, hence the spawned holder.
      :erpc.call(node, Code, :eval_string, [
        """
        spawn(fn ->
          {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
          {:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: Emisar.PubSub.Server)
          Process.sleep(:infinity)
        end)
        """
      ])

      :ok = eventually_pubsub(node)
      {:ok, node: node}
    end

    test "draining this node leaves the other node's subscribers connected", %{node: node} do
      topic = RunnerSocketDrain.drain_topic()
      me_name = :drain_test_collector
      Process.register(self(), me_name)

      {remote, _} =
        :erpc.call(node, Code, :eval_string, [
          """
          spawn(fn ->
            :ok = Phoenix.PubSub.subscribe(Emisar.PubSub.Server, "#{topic}")
            send({:"#{me_name}", :"#{node()}"}, :remote_subscribed)
            loop = fn loop ->
              receive do
                msg -> send({:"#{me_name}", :"#{node()}"}, {:remote_got, msg})
              end
              loop.(loop)
            end
            loop.(loop)
          end)
          """
        ])

      assert_receive :remote_subscribed, 5_000
      :ok = Phoenix.PubSub.subscribe(Emisar.PubSub.Server, topic)

      # Sanity: the nodes are clustered, so a cluster broadcast reaches the
      # remote subscriber (retried until :pg has synced the remote group).
      assert eventually(fn ->
               :ok = Emisar.PubSub.broadcast(topic, :probe)
               receive do: ({:remote_got, :probe} -> true), after: (100 -> false)
             end)

      flush_probes()

      assert RunnerSocketDrain.terminate(:shutdown, %{}) == :ok

      assert_received :runner_socket_drain
      refute_receive {:remote_got, _}, 300
      assert :erpc.call(node, Process, :alive?, [remote])
    end
  end

  defp eventually_pubsub(node) do
    if eventually(fn -> :erpc.call(node, Process, :whereis, [Emisar.PubSub.Server]) != nil end),
      do: :ok
  end

  defp flush_probes do
    receive do
      {:remote_got, _} -> flush_probes()
      :probe -> flush_probes()
    after
      200 -> :ok
    end
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        receive do
        after
          100 -> eventually(fun, tries - 1)
        end
    end
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
