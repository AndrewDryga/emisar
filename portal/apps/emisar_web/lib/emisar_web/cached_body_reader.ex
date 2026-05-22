defmodule EmisarWeb.CachedBodyReader do
  @moduledoc """
  Custom body reader for `Plug.Parsers`. On webhook routes that need to
  verify a signature over the *raw* request body (Stripe), we have to
  stash the bytes before JSON parsing consumes them.

  For all other routes this is a no-op pass-through — the cached body
  doubles the memory used for those requests, which is unacceptable
  on large MCP / runner payloads, so we only cache when the request
  path is in a small allow-list.
  """

  @cache_paths ["/webhooks/stripe"]

  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)

    if conn.request_path in @cache_paths do
      {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}
    else
      {:ok, body, conn}
    end
  end
end
