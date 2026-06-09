defmodule EmisarWeb.Plugs.RateLimit do
  @moduledoc """
  Fixed-window rate limiting for a route, backed by `EmisarWeb.RateLimiter`.

  Wire it as a route-scoped controller plug:

      plug EmisarWeb.Plugs.RateLimit,
        [bucket: "oauth_register", limit: 20, window_ms: 3_600_000, by: :ip]
        when action == :register

  `:by` chooses the bucket key:

    * `:ip` — the client IP (honors `x-forwarded-for` from the trusted
      fly-proxy, falling back to `remote_ip`). Use for unauthenticated routes.
    * `:bearer` — a SHA-256 of the `Authorization: Bearer` token, so a leaked
      key is capped across IPs. Falls back to the IP when no bearer is present.

  Disabled in the test environment (`config :emisar_web, rate_limit_enabled:
  false`) so the fast suite doesn't trip shared counters; `RateLimiter.check/3`
  is unit-tested directly instead.
  """
  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts) do
    %{
      bucket: Keyword.fetch!(opts, :bucket),
      limit: Keyword.fetch!(opts, :limit),
      window_ms: Keyword.fetch!(opts, :window_ms),
      by: Keyword.get(opts, :by, :ip)
    }
  end

  @impl Plug
  def call(conn, %{bucket: bucket, limit: limit, window_ms: window_ms, by: by}) do
    if enabled?() do
      key = {bucket, key_for(conn, by)}

      case EmisarWeb.RateLimiter.check(key, limit, window_ms) do
        :ok -> conn
        {:error, :rate_limited} -> reject(conn, window_ms)
      end
    else
      conn
    end
  end

  defp enabled?, do: Application.get_env(:emisar_web, :rate_limit_enabled, true)

  defp reject(conn, window_ms) do
    retry_after = window_ms |> div(1000) |> max(1)

    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_resp_content_type("application/json")
    |> send_resp(
      429,
      Jason.encode!(%{
        error: "rate_limited",
        message: "Too many requests. Retry in #{retry_after}s."
      })
    )
    |> halt()
  end

  defp key_for(conn, :bearer) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> "key:" <> Base.encode16(:crypto.hash(:sha256, token))
      _ -> client_ip(conn)
    end
  end

  defp key_for(conn, :ip), do: client_ip(conn)

  # The app sits behind fly-proxy, which stamps the true client IP into
  # `Fly-Client-IP` (and overwrites any client-supplied value, so it can't be
  # forged). We deliberately do NOT trust `X-Forwarded-For`: fly *appends* the
  # real client to it, so its leftmost entry is attacker-controlled — keying on
  # that would let a caller rotate the bucket and walk straight past the limit.
  # Fall back to the socket peer for dev / direct connections.
  defp client_ip(conn) do
    case get_req_header(conn, "fly-client-ip") do
      [ip | _] -> ip
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
