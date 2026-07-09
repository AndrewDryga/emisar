defmodule Emisar.Cluster.GCE do
  @moduledoc """
  A libcluster strategy that forms the BEAM cluster from the portal's GCP managed
  instance group, discovering peers via the Compute API instead of DNS.

  Each poll lists the project's RUNNING instances carrying the cluster label
  (`cluster_name=<value>`) and connects to each peer as `<basename>@<internal-ip>`,
  matching the node name set in `rel/env.sh.eex`. The Compute/metadata HTTP lives
  in `Emisar.Cluster.GCE.Client` (the vendor seam); tests inject `:discover_fn`.

  This is the GCP counterpart to the DNSCluster used on Fly: on GCP a MIG has no
  single DNS name resolving to all instances, so we ask the Compute API instead.
  Both are wired mutually-exclusively by env — see `application.ex` + `runtime.exs`.

  Topology `:config` keys:

    * `:project_id`       - **required**, GCP project to query.
    * `:cluster_label`    - label key to filter on (default `"cluster_name"`).
    * `:cluster_value`    - label value to filter on (default `"emisar"`).
    * `:basename`         - node basename (default `"emisar"`).
    * `:polling_interval` - ms between polls (default 30_000).
    * `:backoff_interval` - max ms backoff between discovery retries (default 1_000).
    * `:discover_fn`      - 1-arity `fn(config) -> {:ok, [instance]} | {:error, term}`;
                            a test seam defaulting to `Emisar.Cluster.GCE.Client.discover/1`.
  """
  use GenServer
  use Cluster.Strategy
  alias Cluster.Strategy.State
  alias Emisar.Cluster.GCE.Client
  require Logger

  @default_polling_interval :timer.seconds(30)

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init([%State{} = state]) do
    {:ok, %State{state | meta: MapSet.new()}, {:continue, :poll}}
  end

  @impl true
  def handle_continue(:poll, %State{} = state), do: {:noreply, poll(state)}

  @impl true
  def handle_info(:poll, %State{} = state), do: {:noreply, poll(state)}

  # ── Discovery (overridable in tests via :discover_fn) ──────────────────────

  @doc false
  def list_cluster_nodes(%State{config: config}) do
    discover_fn = Keyword.get(config, :discover_fn, &Client.discover/1)
    basename = Keyword.get(config, :basename, "emisar")

    with {:ok, instances} <- discover_fn.(config) do
      {:ok, nodes_from_instances(instances, basename)}
    end
  end

  @doc false
  def nodes_from_instances(instances, basename) do
    Enum.flat_map(instances, fn
      %{"networkInterfaces" => [%{"networkIP" => ip} | _]} when is_binary(ip) and ip != "" ->
        # Node names must be atoms, and the set is bounded by the MIG size — these
        # are our own GCP instances, not user/runner/LLM input, so there is no
        # atom-table exhaustion vector (the IL-14 concern).
        # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
        [:"#{basename}@#{ip}"]

      _ ->
        []
    end)
  end

  # ── Connect / disconnect bookkeeping ───────────────────────────────────────

  defp poll(%State{} = state) do
    case fetch_nodes(state) do
      {:ok, nodes} -> reconcile(state, MapSet.new(nodes))
      {:error, _reason} -> schedule_next_poll(state) && state
    end
  end

  defp reconcile(%State{topology: topology, meta: known} = state, discovered) do
    removed = MapSet.difference(known, discovered)
    added = MapSet.difference(discovered, known)

    known =
      case Cluster.Strategy.disconnect_nodes(
             topology,
             state.disconnect,
             state.list_nodes,
             MapSet.to_list(removed)
           ) do
        :ok ->
          discovered

        {:error, bad_nodes} ->
          Logger.warning("cluster: can't disconnect from some nodes: #{inspect(bad_nodes)}")
          # keep the nodes we failed to drop, so the next poll retries the disconnect
          Enum.reduce(bad_nodes, discovered, fn {node, _}, acc -> MapSet.put(acc, node) end)
      end

    known =
      case Cluster.Strategy.connect_nodes(
             topology,
             state.connect,
             state.list_nodes,
             MapSet.to_list(added)
           ) do
        :ok ->
          known

        {:error, bad_nodes} ->
          Logger.warning("cluster: can't connect to some nodes: #{inspect(bad_nodes)}")
          # forget the nodes we failed to reach, so the next poll retries the connect
          Enum.reduce(bad_nodes, known, fn {node, _}, acc -> MapSet.delete(acc, node) end)
      end

    schedule_next_poll(state)
    %State{state | meta: known}
  end

  defp fetch_nodes(%State{config: config} = state, remaining_retries \\ 3) do
    case list_cluster_nodes(state) do
      {:ok, nodes} ->
        Logger.debug("cluster: discovered #{length(nodes)} node(s): #{inspect(nodes)}")
        {:ok, nodes}

      {:error, reason} when remaining_retries > 0 ->
        Logger.warning("cluster discovery failed; retrying: #{inspect(reason)}")
        backoff = :rand.uniform(Keyword.get(config, :backoff_interval, 1_000)) + 1
        Process.sleep(backoff)
        fetch_nodes(state, remaining_retries - 1)

      {:error, reason} ->
        Logger.error("cluster discovery failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp schedule_next_poll(%State{config: config}) do
    interval = Keyword.get(config, :polling_interval, @default_polling_interval)
    Process.send_after(self(), :poll, interval)
  end
end
