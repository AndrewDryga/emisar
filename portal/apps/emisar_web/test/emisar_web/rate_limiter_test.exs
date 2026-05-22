defmodule EmisarWeb.RateLimiterTest do
  use ExUnit.Case, async: false

  alias EmisarWeb.RateLimiter

  setup do
    :ok = RateLimiter.init()
    RateLimiter.reset_all()
    :ok
  end

  test "allows N events then rejects" do
    key = "test:#{System.unique_integer([:positive])}"
    for _ <- 1..3, do: assert(:ok == RateLimiter.check(key, 3, 60_000))

    assert {:error, :rate_limited, retry_after} = RateLimiter.check(key, 3, 60_000)
    assert retry_after > 0
    assert retry_after <= 60_000
  end

  test "different keys have independent buckets" do
    a = "test:a:#{System.unique_integer([:positive])}"
    b = "test:b:#{System.unique_integer([:positive])}"

    for _ <- 1..2, do: assert(:ok == RateLimiter.check(a, 2, 60_000))
    assert {:error, :rate_limited, _} = RateLimiter.check(a, 2, 60_000)
    # b should still be fresh.
    assert :ok == RateLimiter.check(b, 2, 60_000)
  end

  test "window expiry resets the bucket" do
    key = "test:exp:#{System.unique_integer([:positive])}"
    assert :ok == RateLimiter.check(key, 1, 10)
    assert {:error, :rate_limited, _} = RateLimiter.check(key, 1, 10)
    Process.sleep(20)
    assert :ok == RateLimiter.check(key, 1, 10)
  end

  test "atomic cap holds under concurrent contention" do
    # 16 concurrent processes pounding the same bucket, budget = 5.
    # The cap must hold exactly: at most 5 :ok results, rest rejected.
    # Under the previous lookup→compare→increment shape this was racy
    # and could yield 6+ successes.
    key = "test:concurrent:#{System.unique_integer([:positive])}"

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
