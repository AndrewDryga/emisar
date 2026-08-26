defmodule EmisarWeb.AuditDownloadLimiter do
  @moduledoc """
  Node-local concurrency bound for audit CSV materialization.

  A CSV may occupy up to 256 MiB of the node's temporary volume. Only one
  artifact per account and two per node may be prepared at once. Process
  monitors release leases when a request exits abnormally; normal callers
  release synchronously in `after`.
  """

  use GenServer

  @max_per_node 2

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Runs one audit CSV request while its account and node have capacity."
  @spec run(Ecto.UUID.t(), (-> result)) :: result | {:error, :audit_download_saturated}
        when result: term()
  def run(account_id, fun) when is_binary(account_id) and is_function(fun, 0) do
    case GenServer.call(__MODULE__, {:acquire, account_id, self()}) do
      {:ok, lease} ->
        try do
          fun.()
        after
          :ok = GenServer.call(__MODULE__, {:release, lease})
        end

      :saturated ->
        {:error, :audit_download_saturated}
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{accounts: MapSet.new(), leases: %{}}}

  @impl true
  def handle_call({:acquire, account_id, pid}, _from, state) do
    if map_size(state.leases) >= @max_per_node or MapSet.member?(state.accounts, account_id) do
      {:reply, :saturated, state}
    else
      lease = Process.monitor(pid)

      next = %{
        accounts: MapSet.put(state.accounts, account_id),
        leases: Map.put(state.leases, lease, account_id)
      }

      {:reply, {:ok, lease}, next}
    end
  end

  def handle_call({:release, lease}, _from, state),
    do: {:reply, :ok, release(state, lease)}

  @impl true
  def handle_info({:DOWN, lease, :process, _pid, _reason}, state),
    do: {:noreply, release(state, lease)}

  defp release(state, lease) do
    case Map.pop(state.leases, lease) do
      {nil, _leases} ->
        state

      {account_id, leases} ->
        _ = Process.demonitor(lease, [:flush])
        %{accounts: MapSet.delete(state.accounts, account_id), leases: leases}
    end
  end
end
