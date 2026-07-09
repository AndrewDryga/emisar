defmodule Emisar.Cluster.GCETest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Cluster.Strategy.State
  alias Emisar.Cluster.GCE

  defp instance(ip), do: %{"networkInterfaces" => [%{"networkIP" => ip}]}

  describe "nodes_from_instances/2" do
    test "maps instance internal IPs to <basename>@<ip> nodes" do
      assert GCE.nodes_from_instances([instance("10.82.0.2"), instance("10.82.0.3")], "emisar") ==
               [:"emisar@10.82.0.2", :"emisar@10.82.0.3"]
    end

    test "skips instances without a network IP (e.g. still booting)" do
      assert GCE.nodes_from_instances(
               [
                 %{"name" => "booting"},
                 %{"networkInterfaces" => [%{"networkIP" => nil}]},
                 %{"networkInterfaces" => [%{"networkIP" => ""}]},
                 instance("10.82.0.9")
               ],
               "emisar"
             ) ==
               [:"emisar@10.82.0.9"]
    end
  end

  describe "list_cluster_nodes/1" do
    test "runs the injected discover_fn through the IP→node mapping" do
      state = %State{config: [discover_fn: fn _ -> {:ok, [instance("10.0.0.5")]} end]}
      assert {:ok, [:"emisar@10.0.0.5"]} = GCE.list_cluster_nodes(state)
    end

    test "propagates discovery errors" do
      state = %State{config: [discover_fn: fn _ -> {:error, :boom} end]}
      assert {:error, :boom} = GCE.list_cluster_nodes(state)
    end
  end

  describe "polling" do
    test "connects to every discovered peer" do
      test_pid = self()
      instances = [instance("10.0.0.1"), instance("10.0.0.2")]

      state = %State{
        topology: :test,
        connect: {__MODULE__, :record_connect, [test_pid]},
        disconnect: {__MODULE__, :record_disconnect, [test_pid]},
        list_nodes: {__MODULE__, :list_nodes, []},
        config: [discover_fn: fn _ -> {:ok, instances} end, polling_interval: 60_000]
      }

      {:ok, pid} = GCE.start_link([state])
      assert_receive {:connect, :"emisar@10.0.0.1"}, 1_000
      assert_receive {:connect, :"emisar@10.0.0.2"}, 1_000
      GenServer.stop(pid)
    end

    test "survives a discovery failure without connecting or crashing" do
      test_pid = self()

      state = %State{
        topology: :test,
        connect: {__MODULE__, :record_connect, [test_pid]},
        disconnect: {__MODULE__, :record_disconnect, [test_pid]},
        list_nodes: {__MODULE__, :list_nodes, []},
        config: [
          discover_fn: fn _ -> {:error, :unreachable} end,
          polling_interval: 60_000,
          backoff_interval: 2
        ]
      }

      log =
        capture_log(fn ->
          {:ok, pid} = GCE.start_link([state])
          refute_receive {:connect, _}, 150
          assert Process.alive?(pid)
          GenServer.stop(pid)
        end)

      assert log =~ "cluster discovery failed"
    end
  end

  # Exported MFAs libcluster invokes via apply/3 (it checks function_exported?/3).
  def record_connect(test_pid, node) do
    send(test_pid, {:connect, node})
    true
  end

  def record_disconnect(test_pid, node) do
    send(test_pid, {:disconnect, node})
    true
  end

  def list_nodes, do: []
end
