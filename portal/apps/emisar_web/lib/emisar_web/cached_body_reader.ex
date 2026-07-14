defmodule EmisarWeb.CachedBodyReader do
  @moduledoc """
  Custom body reader for `Plug.Parsers`. Security boundaries that verify
  request bytes or exact JSON value slices must retain the body before the
  ordinary parser consumes it.

  For all other routes this is a no-op pass-through. Cached bodies double the
  request's transient memory, so the allow-list stays deliberately small and
  every listed route enforces its own request-size limit.
  """

  @cached_body_limits %{
    "/api/mcp/rpc" => 128 * 1024,
    "/webhooks/paddle" => 1024 * 1024
  }

  def read_body(conn, opts) do
    opts = bound_length(opts, Map.get(@cached_body_limits, conn.request_path))

    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        maybe_cache_body(conn, body)

      {:more, body, conn} ->
        # Preserve Plug.Parsers' size limit behavior. The JSON parser converts
        # this to a controlled :too_large response; caching a partial signed
        # payload would be both useless and misleading.
        {:more, body, conn}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_cache_body(conn, body) do
    if Map.has_key?(@cached_body_limits, conn.request_path) do
      {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}
    else
      {:ok, body, conn}
    end
  end

  defp bound_length(opts, nil), do: opts

  defp bound_length(opts, limit) do
    Keyword.update(opts, :length, limit, &min(&1, limit))
  end
end
