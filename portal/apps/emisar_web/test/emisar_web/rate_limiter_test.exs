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

    # A window wide enough that two calls cannot straddle its edge. At
    # window_ms = 1 they had to land in the SAME wall-clock millisecond: under
    # parallel gate load the clock ticked between them, they fell in different
    # windows, and the second was allowed — the test failed having proved the
    # opposite of a bug.
    window_ms = 50
    ensure_room_in_window(window_ms)

    assert RateLimiter.check(k, 1, window_ms) == :ok
    assert RateLimiter.check(k, 1, window_ms) == {:error, :rate_limited}

    # Cross the edge deliberately rather than waiting and hoping.
    spin_until(next_window_start(window_ms))
    assert RateLimiter.check(k, 1, window_ms) == :ok
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

  defp spin_until(ms) do
    if System.system_time(:millisecond) < ms, do: spin_until(ms), else: :ok
  end

  defp next_window_start(window_ms) do
    (div(System.system_time(:millisecond), window_ms) + 1) * window_ms
  end

  # Only spins when the current window is nearly over, so the common run costs
  # nothing and the assertions still get the whole window to themselves.
  defp ensure_room_in_window(window_ms) do
    edge = next_window_start(window_ms)

    if edge - System.system_time(:millisecond) < div(window_ms, 2) do
      spin_until(edge)
    else
      :ok
    end
  end
end
