defmodule EmisarWeb.RateLimiterTest do
  # async: true is safe — every test uses `unique_int()` in its key, so
  # the per-test buckets in the shared ETS table never collide.
  use ExUnit.Case, async: true

  alias EmisarWeb.RateLimiter

  setup do
    # `init/0` is idempotent; safe to call on every test in case
    # something else nuked the table.
    :ok = RateLimiter.init()
    :ok
  end

  defp unique_key(suffix \\ ""),
    do: "test:#{suffix}:#{System.unique_integer([:positive])}"

  describe "check/3" do
    test "allows N events then rejects on the (N+1)th" do
      key = unique_key()
      for _ <- 1..3, do: assert :ok == RateLimiter.check(key, 3, 60_000)

      assert {:error, :rate_limited, retry_after} = RateLimiter.check(key, 3, 60_000)
      assert retry_after > 0
      assert retry_after <= 60_000
    end

    test "different keys have independent buckets" do
      a = unique_key("a")
      b = unique_key("b")

      for _ <- 1..2, do: assert :ok == RateLimiter.check(a, 2, 60_000)
      assert {:error, :rate_limited, _} = RateLimiter.check(a, 2, 60_000)

      # `b` is fresh — `a`'s rejection didn't leak across keys.
      assert :ok == RateLimiter.check(b, 2, 60_000)
    end

    test "window expiry resets the bucket and accepts again" do
      key = unique_key("expiry")
      # 1-event bucket with a 10ms window — generous enough that the
      # 30ms sleep below clears it even under CI scheduler jitter.
      assert :ok == RateLimiter.check(key, 1, 10)
      assert {:error, :rate_limited, _} = RateLimiter.check(key, 1, 10)

      # Bumped from 20ms → 30ms to keep this reliable under CI load.
      Process.sleep(30)

      assert :ok == RateLimiter.check(key, 1, 10)
    end

    test "atomic cap holds under concurrent contention" do
      # 16 concurrent processes hit the same bucket with budget=5. The
      # cap must hold exactly: ≤5 `:ok`s, the rest rejected. Under the
      # previous lookup→compare→increment shape this was racy and
      # could yield 6+ successes — the fix uses `:ets.update_counter`
      # with the {Pos, Incr, Threshold, SetValue} form to cap atomically.
      key = unique_key("concurrent")

      results =
        1..16
        |> Enum.map(fn _ -> Task.async(fn -> RateLimiter.check(key, 5, 60_000) end) end)
        |> Enum.map(&Task.await(&1, 1_000))

      ok = Enum.count(results, &(&1 == :ok))
      rejected = Enum.count(results, &match?({:error, :rate_limited, _}, &1))

      assert ok == 5, "expected exactly 5 :ok under contention, got #{ok}"
      assert rejected == 11
    end
  end

  describe "init/0" do
    test "is idempotent — multiple calls don't error" do
      assert :ok = RateLimiter.init()
      assert :ok = RateLimiter.init()
      assert :ok = RateLimiter.init()
    end
  end

  describe "ip_key/1" do
    test "stringifies an IPv4 tuple" do
      conn = %Plug.Conn{remote_ip: {10, 0, 0, 1}}
      assert RateLimiter.ip_key(conn) == "10.0.0.1"
    end

    test "stringifies an IPv6 tuple" do
      conn = %Plug.Conn{remote_ip: {8193, 3512, 0, 0, 0, 0, 0, 1}}
      assert RateLimiter.ip_key(conn) =~ ":"
    end

    test "falls back to \"unknown\" for non-Conn inputs" do
      assert RateLimiter.ip_key(:nope) == "unknown"
      assert RateLimiter.ip_key(nil) == "unknown"
    end
  end
end
