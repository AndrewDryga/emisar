defmodule EmisarWeb.Plugs.RateLimit do
  @moduledoc """
  Fixed-window rate limiting for a route, backed by `EmisarWeb.RateLimiter`.

  Wire it as a route-scoped controller plug:

      plug EmisarWeb.Plugs.RateLimit,
        [bucket: "oauth_register", limit: 20, window_ms: 3_600_000, by: :ip]
        when action == :register

  `:by` chooses the bucket key:

    * `:ip` — the client IP from the trusted GCP forwarding tail, falling back
      to `remote_ip` for direct connections. Use for unauthenticated routes.
    * `:bearer` — a SHA-256 of the `Authorization: Bearer` token, so a leaked
      key is capped across IPs. Falls back to the IP when no bearer is present.

  The on/off switch and the `RateLimiter` delegation live in
  `EmisarWeb.Throttle` (shared with the LiveView send paths that can't sit
  behind a plug); it is off in the test env so the fast suite doesn't trip
  shared counters.
  """
  @behaviour Plug

  import Plug.Conn
  alias EmisarWeb.RequestContext

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
    case EmisarWeb.Throttle.check(bucket, key_for(conn, by), limit, window_ms) do
      :ok -> conn
      {:error, :rate_limited} -> reject(conn, window_ms)
    end
  end

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
      ["Bearer " <> token | _] -> "key:" <> Emisar.Crypto.hash_hex(token)
      _ -> RequestContext.client_ip(conn)
    end
  end

  defp key_for(conn, :ip), do: RequestContext.client_ip(conn)
end
