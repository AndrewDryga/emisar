defmodule EmisarWeb.RunnerSocketDrainClusterTest do
  @moduledoc """
  Two real nodes: the shutdown drain reaches the subscribers on this node
  (subscribed as RunnerSocket does) and none on the peer. Starting
  distribution changes `node()`/`Node.list()` VM-wide, so this lives in its
  own non-async module.
  """
  use ExUnit.Case, async: false
  alias EmisarWeb.RunnerSocketDrain

  setup_all do
    # Distribution is needed only here; epmd may not be running yet.
    {_, epmd_was_down} = System.cmd("epmd", ["-names"], stderr_to_stdout: true)
    System.cmd("epmd", ["-daemon"])

    started_node? =
      if Node.alive?() do
        false
      else
        {:ok, _} = Node.start(:"drain_test@127.0.0.1", :longnames)
        true
      end

    on_exit(fn ->
      if started_node?, do: Node.stop()
      # Only kill an epmd this module started.
      if started_node? and epmd_was_down != 0, do: System.cmd("epmd", ["-kill"])
    end)

    :ok
  end

  setup do
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
end
