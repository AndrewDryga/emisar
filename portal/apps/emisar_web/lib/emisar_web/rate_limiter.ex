defmodule EmisarWeb.RateLimiter do
  @moduledoc """
  A small fixed-window rate limiter backed by one public ETS table.

  No external dependency on purpose: for a security product every dependency
  is attack surface, and a handful of abuse-prevention counters don't warrant
  one. `check/3` is a single atomic `:ets.update_counter`; a periodic sweep
  drops expired windows so the table stays bounded.

  This is coarse abuse prevention (a fixed window can allow a brief burst
  across a window boundary), not a precise quota. It fronts the
  unauthenticated OAuth endpoints and the MCP surface via
  `EmisarWeb.Plugs.RateLimit`.
  """
  use GenServer

  @table __MODULE__
  @sweep_interval_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Records one hit for `key` and returns `:ok` while at most `limit` hits have
  occurred in the current `window_ms` window, otherwise `{:error, :rate_limited}`.

  The ETS object is `{{key, window_index}, count, expires_at_ms}`; the count is
  bumped atomically and `expires_at` is set once (on the window's first hit) so
  the sweep can reclaim it.
  """
  @spec check(term(), pos_integer(), pos_integer()) :: :ok | {:error, :rate_limited}
  def check(key, limit, window_ms) when is_integer(limit) and is_integer(window_ms) do
    now = System.system_time(:millisecond)
    window = div(now, window_ms)
    entry = {key, window}
    expires_at = (window + 1) * window_ms
    count = :ets.update_counter(@table, entry, {2, 1}, {entry, 0, expires_at})
    if count <= limit, do: :ok, else: {:error, :rate_limited}
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:millisecond)
    # Objects are {{key, window}, count, expires_at}; drop the expired ones.
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
