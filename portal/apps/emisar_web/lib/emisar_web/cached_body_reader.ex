defmodule EmisarWeb.CachedBodyReader do
  @moduledoc """
  Custom body reader for `Plug.Parsers`. On webhook routes that need to
  verify a signature over the *raw* request body (Paddle), we have to
  stash the bytes before JSON parsing consumes them.

  For all other routes this is a no-op pass-through — the cached body
  doubles the memory used for those requests, which is unacceptable
  on large MCP / runner payloads, so we only cache when the request
  path is in a small allow-list.
  """

  @cache_paths ["/webhooks/paddle"]

  def read_body(conn, opts) do
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

  defp maybe_cache_body(%{request_path: path} = conn, body) when path in @cache_paths,
    do: {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}

  defp maybe_cache_body(conn, body), do: {:ok, body, conn}
end
