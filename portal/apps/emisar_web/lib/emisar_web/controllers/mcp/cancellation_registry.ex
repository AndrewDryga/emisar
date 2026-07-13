defmodule EmisarWeb.MCP.CancellationRegistry do
  @moduledoc false

  use GenServer

  @by_topic __MODULE__
  @by_expiry Module.concat(__MODULE__, ByExpiry)
  @retention_ms 360_000
  @sweep_interval_ms 60_000
  @max_entries 50_000
  @cluster_call_timeout_ms 500

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Record a cancellation on every currently connected portal node."
  @spec record(String.t()) :: :ok
  def record(topic) when is_binary(topic) do
    # Registration is synchronous across the current BEAM cluster. The exact
    # PubSub signal is sent only after this returns, so a target either observes
    # its tombstone after subscribing or receives the subsequent live signal.
    _ = cluster_call({:record, topic})
    :ok
  end

  @doc "Whether this node has a live cancellation tombstone for the topic."
  @spec cancelled?(String.t()) :: boolean()
  def cancelled?(topic) when is_binary(topic) do
    case :ets.lookup(@by_topic, topic) do
      [{^topic, expires_at}] -> expires_at > System.monotonic_time(:millisecond)
      [] -> false
    end
  rescue
    # The supervisor starts this registry before the Endpoint. During a rare
    # registry restart, cancellation degrades to the live PubSub signal rather
    # than failing an otherwise valid MCP request.
    ArgumentError -> false
  end

  @doc "Forget a consumed tombstone locally and across the cluster."
  @spec complete(String.t()) :: :ok
  def complete(topic) when is_binary(topic) do
    if cancelled?(topic) do
      _ = cluster_call({:complete, topic})
      :ok
    else
      :ok
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@by_topic, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@by_expiry, [:ordered_set, :private, :named_table])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:record, topic}, _from, state) do
    insert(topic)
    {:reply, :ok, state}
  end

  def handle_call({:complete, topic}, _from, state) do
    delete(topic)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep_expired(System.monotonic_time(:millisecond))
    schedule_sweep()
    {:noreply, state}
  end

  defp insert(topic) do
    delete(topic)
    evict_oldest_if_full()
    expires_at = System.monotonic_time(:millisecond) + @retention_ms
    true = :ets.insert(@by_topic, {topic, expires_at})
    true = :ets.insert(@by_expiry, {{expires_at, topic}})
  end

  defp delete(topic) do
    case :ets.take(@by_topic, topic) do
      [{^topic, expires_at}] -> :ets.delete(@by_expiry, {expires_at, topic})
      [] -> true
    end

    :ok
  end

  defp evict_oldest_if_full do
    if :ets.info(@by_topic, :size) >= @max_entries do
      case :ets.first(@by_expiry) do
        {expires_at, topic} ->
          true = :ets.delete(@by_expiry, {expires_at, topic})
          true = :ets.delete(@by_topic, topic)

        :"$end_of_table" ->
          :ok
      end
    end
  end

  defp sweep_expired(now) do
    case :ets.first(@by_expiry) do
      {expires_at, topic} when expires_at <= now ->
        delete(topic)
        sweep_expired(now)

      _ ->
        :ok
    end
  end

  defp cluster_call(request) do
    GenServer.multi_call(
      [node() | Node.list()],
      __MODULE__,
      request,
      @cluster_call_timeout_ms
    )
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
