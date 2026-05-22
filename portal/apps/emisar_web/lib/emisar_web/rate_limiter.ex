defmodule EmisarWeb.RateLimiter do
  @moduledoc """
  In-memory token bucket for hot auth surfaces. Backed by an ETS table
  owned by the EmisarWeb.Endpoint supervision tree. Keys are arbitrary
  strings; callers compose them (e.g. "sign_in:ip:1.2.3.4").

  Scope: single-node. Production runs Phoenix on one fly.io machine so
  this is sufficient. For multi-node deployments switch to a shared
  store (Redis / Hammer + Mnesia). The check/3 contract is unchanged
  in that case.

  Behaviour: fixed window. When a bucket fills, all subsequent
  requests in the window get `{:error, :rate_limited, retry_after_ms}`.
  Caller decides what to do (typically 429 + audit log).
  """

  @table :emisar_rate_limit

  @doc "Called once from supervision tree. Idempotent."
  def init do
    case :ets.info(@table) do
      :undefined ->
        # Wrap in try/rescue for the (rare) race where two callers
        # observe :undefined and both try to create — :ets.new raises
        # `ArgumentError` on duplicate name; we just treat that as
        # "someone else won the race" and proceed.
        try do
          :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

        :ok

      _ ->
        :ok
    end
  end

  # Self-heal: callers (controllers, LV handlers) can hit this before
  # Application.start ran (in dev, when this module was added after
  # the BEAM had already booted; in tests, when init was never called).
  # Cheap branch — `:ets.info` is in-process and fast.
  defp ensure_table do
    if :ets.info(@table) == :undefined, do: init(), else: :ok
  end

  @doc """
  Allow at most `max` events under `key` per `window_ms` window. Returns
  :ok if within budget, {:error, :rate_limited, retry_after_ms} otherwise.

  The window resets after `window_ms` have elapsed since the *first*
  event in the current bucket.
  """
  @spec check(String.t(), pos_integer(), pos_integer()) ::
          :ok | {:error, :rate_limited, non_neg_integer()}
  def check(key, max, window_ms) when is_binary(key) do
    ensure_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, _count, started_at}] when now - started_at < window_ms ->
        # Window still open. Atomically bump the count, capping at
        # max + 1 so concurrent calls can't drift past the budget:
        # the {Pos, Incr, Threshold, SetValue} form caps the result.
        new_count =
          :ets.update_counter(@table, key, {2, 1, max + 1, max + 1})

        if new_count > max do
          {:error, :rate_limited, window_ms - (now - started_at)}
        else
          :ok
        end

      _ ->
        # Window expired or first hit. Insert (no-op if a concurrent
        # caller already inserted) and treat as one use.
        :ets.insert(@table, {key, 1, now})
        :ok
    end
  end

  @doc "Clears all buckets. Test/debug only."
  def reset_all do
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  Stringifies `conn.remote_ip` for use as a rate-limit bucket key.
  Falls back to "unknown" if the tuple isn't an IP (test sockets,
  unusual transports). Behind a fly proxy without a RemoteIp plug
  this returns the proxy IP — see `docs/operations.md` known gaps.
  """
  @spec ip_key(Plug.Conn.t()) :: String.t()
  def ip_key(%Plug.Conn{remote_ip: ip}) when is_tuple(ip),
    do: ip |> :inet_parse.ntoa() |> to_string()

  def ip_key(_), do: "unknown"
end
