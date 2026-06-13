defmodule EmisarWeb.RateLimiterTest do
  use ExUnit.Case, async: true

  alias EmisarWeb.RateLimiter

  # Unique keys per test so the shared ETS table doesn't couple async tests.
  defp key(tag), do: {"test", "#{tag}-#{System.unique_integer([:positive])}"}

  test "allows up to the limit within a window, then rejects" do
    k = key("limit")

    for _ <- 1..5 do
      assert RateLimiter.check(k, 5, 60_000) == :ok
    end

    assert RateLimiter.check(k, 5, 60_000) == {:error, :rate_limited}
    assert RateLimiter.check(k, 5, 60_000) == {:error, :rate_limited}
  end

  test "different keys keep independent counters" do
    a = key("a")
    b = key("b")

    assert RateLimiter.check(a, 1, 60_000) == :ok
    assert RateLimiter.check(a, 1, 60_000) == {:error, :rate_limited}
    # b is untouched by a's exhaustion.
    assert RateLimiter.check(b, 1, 60_000) == :ok
  end

  test "the counter resets when the window rolls over" do
    k = key("window")

    # window_ms = 1 → each wall-clock millisecond is its own window.
    assert RateLimiter.check(k, 1, 1) == :ok
    assert RateLimiter.check(k, 1, 1) == {:error, :rate_limited}

    spin_past(System.system_time(:millisecond))
    assert RateLimiter.check(k, 1, 1) == :ok
  end

  test "the periodic sweep reclaims expired windows so the table stays bounded" do
    k = key("sweep")

    # window_ms = 1 → the entry's window expires almost immediately.
    assert RateLimiter.check(k, 1, 1) == :ok
    assert ets_entries(k) != []

    # Let its expires_at fall into the past, then run the sweep. Sending
    # :sweep then calling :sys.get_state syncs on it (mailbox order), so the
    # select_delete has run by the time get_state returns.
    spin_past(System.system_time(:millisecond) + 2)
    send(Process.whereis(RateLimiter), :sweep)
    :sys.get_state(RateLimiter)

    assert ets_entries(k) == []
  end

  defp ets_entries(key), do: :ets.match_object(RateLimiter, {{key, :_}, :_, :_})

  # Busy-wait until the wall clock ticks past `ms` (resolves in well under a
  # millisecond — no Process.sleep). Time is the synchronization here.
  defp spin_past(ms) do
    if System.system_time(:millisecond) <= ms, do: spin_past(ms), else: :ok
  end
end
