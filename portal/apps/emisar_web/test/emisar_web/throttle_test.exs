defmodule EmisarWeb.ThrottleTest do
  @moduledoc """
  The shared web-layer abuse gate. The suite-wide config disables it
  (shared ETS counters would make unrelated tests flaky), so the tests
  that exercise the live path flip it on locally — hence `async: false`.
  """
  use ExUnit.Case, async: false
  alias EmisarWeb.Throttle

  # Unique bucket per test so the shared ETS table doesn't couple tests.
  defp unique_bucket, do: "test-throttle-#{System.unique_integer([:positive])}"

  defp enable_rate_limiting do
    Emisar.Config.put_override(:emisar_web, :rate_limit_enabled, true)
  end

  test "allows up to the limit, then rate-limits" do
    enable_rate_limiting()
    bucket = unique_bucket()

    assert Throttle.check(bucket, "k", 2, 60_000) == :ok
    assert Throttle.check(bucket, "k", 2, 60_000) == :ok
    assert Throttle.check(bucket, "k", 2, 60_000) == {:error, :rate_limited}
  end

  test "different keys in a bucket get independent windows" do
    enable_rate_limiting()
    bucket = unique_bucket()

    assert Throttle.check(bucket, "a", 1, 60_000) == :ok
    assert Throttle.check(bucket, "a", 1, 60_000) == {:error, :rate_limited}
    # A different key (e.g. another recipient email) is its own window.
    assert Throttle.check(bucket, "b", 1, 60_000) == :ok
  end

  test "the suite-wide disable flag bypasses it entirely (default test config)" do
    # No enable_rate_limiting/0 here — relies on the test-env default of
    # rate_limit_enabled: false, so even past the limit it never rejects.
    bucket = unique_bucket()

    assert Throttle.check(bucket, "k", 1, 60_000) == :ok
    assert Throttle.check(bucket, "k", 1, 60_000) == :ok
    assert Throttle.check(bucket, "k", 1, 60_000) == :ok
  end
end
