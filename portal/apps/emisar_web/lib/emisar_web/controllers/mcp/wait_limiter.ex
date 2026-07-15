defmodule EmisarWeb.MCP.WaitLimiter do
  @moduledoc """
  Node-local concurrency bound for authenticated MCP long polls.

  The key uses the API-key credential lineage, so an automatic rotation cannot
  multiply one client's allowance. Process monitors return leases after an
  abnormal request exit; normal callers release synchronously in `after`.
  """

  use GenServer

  @max_per_credential 8

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Runs one long poll while its credential lineage has capacity."
  @spec run(Plug.Conn.t(), (-> result)) :: result | {:error, :wait_saturated} when result: term()
  def run(
        %{
          assigns: %{
            api_key: %{id: key_id, credential_lineage_id: lineage_id},
            current_subject: %{account: %{id: account_id}}
          }
        },
        fun
      )
      when is_function(fun, 0) do
    key = {account_id, lineage_id || key_id}

    case GenServer.call(__MODULE__, {:acquire, key, self()}) do
      {:ok, lease} ->
        try do
          fun.()
        after
          :ok = GenServer.call(__MODULE__, {:release, lease})
        end

      :saturated ->
        {:error, :wait_saturated}
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{counts: %{}, leases: %{}}}

  @impl true
  def handle_call({:acquire, key, pid}, _from, state) do
    if Map.get(state.counts, key, 0) >= @max_per_credential do
      {:reply, :saturated, state}
    else
      lease = Process.monitor(pid)

      next = %{
        counts: Map.update(state.counts, key, 1, &(&1 + 1)),
        leases: Map.put(state.leases, lease, key)
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

      {key, leases} ->
        _ = Process.demonitor(lease, [:flush])

        counts =
          case Map.fetch!(state.counts, key) do
            1 -> Map.delete(state.counts, key)
            count -> Map.put(state.counts, key, count - 1)
          end

        %{counts: counts, leases: leases}
    end
  end
end
