defmodule EmisarWeb.Plugs.RateLimitTest do
  @moduledoc """
  The route-scoped fixed-window limiter. The suite-wide config disables
  it (shared counters would make unrelated tests flaky), so these tests
  flip it on locally — hence `async: false`.
  """
  use EmisarWeb.ConnCase, async: false
  alias EmisarWeb.Plugs.RateLimit

  defp unique_bucket, do: "test-bucket-#{System.unique_integer([:positive])}"

  defp enable_rate_limiting do
    previous = Application.get_env(:emisar_web, :rate_limit_enabled, true)
    Application.put_env(:emisar_web, :rate_limit_enabled, true)
    on_exit(fn -> Application.put_env(:emisar_web, :rate_limit_enabled, previous) end)
  end

  test "passes under the limit, rejects 429 + Retry-After over it", %{conn: conn} do
    enable_rate_limiting()
    opts = RateLimit.init(bucket: unique_bucket(), limit: 2, window_ms: 60_000, by: :ip)

    assert %{halted: false} = RateLimit.call(conn, opts)
    assert %{halted: false} = RateLimit.call(conn, opts)

    rejected = RateLimit.call(conn, opts)
    assert rejected.halted
    assert rejected.status == 429
    assert get_resp_header(rejected, "retry-after") == ["60"]
    assert rejected.resp_body =~ "rate_limited"
  end

  test "keys by fly-client-ip, so different clients get separate windows", %{conn: conn} do
    enable_rate_limiting()
    opts = RateLimit.init(bucket: unique_bucket(), limit: 1, window_ms: 60_000, by: :ip)

    first = put_req_header(conn, "fly-client-ip", "203.0.113.1")
    second = put_req_header(conn, "fly-client-ip", "203.0.113.2")

    assert %{halted: false} = RateLimit.call(first, opts)
    assert %{halted: true} = RateLimit.call(first, opts)
    # A different client is a different bucket — still under its limit.
    assert %{halted: false} = RateLimit.call(second, opts)
  end

  test ":bearer keys on the token digest and caps it across IPs", %{conn: conn} do
    enable_rate_limiting()
    opts = RateLimit.init(bucket: unique_bucket(), limit: 1, window_ms: 60_000, by: :bearer)

    with_token = put_req_header(conn, "authorization", "Bearer emk-leaked")

    assert %{halted: false} = RateLimit.call(with_token, opts)

    # Same token from a "different IP" still hits the same bucket.
    assert %{halted: true} =
             with_token
             |> put_req_header("fly-client-ip", "198.51.100.7")
             |> RateLimit.call(opts)

    # No bearer falls back to the IP bucket — independent of the token's.
    assert %{halted: false} = RateLimit.call(conn, opts)
  end

  test "the suite-wide disable flag bypasses the limiter entirely", %{conn: conn} do
    # Default test config: rate_limit_enabled: false — no env flip here.
    opts = RateLimit.init(bucket: unique_bucket(), limit: 1, window_ms: 60_000, by: :ip)

    assert %{halted: false} = RateLimit.call(conn, opts)
    assert %{halted: false} = RateLimit.call(conn, opts)
    assert %{halted: false} = RateLimit.call(conn, opts)
  end
end
