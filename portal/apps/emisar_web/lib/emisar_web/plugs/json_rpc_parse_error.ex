defmodule EmisarWeb.Plugs.JSONRPCParseError do
  @moduledoc """
  Wraps `Plug.Parsers` so a malformed body on the JSON-RPC endpoint
  (`/api/mcp/rpc`) returns the spec's `-32700` parse-error envelope at HTTP 400,
  not the generic `Plug.Parsers` 400 — an MCP client parses the response for the
  JSON-RPC error shape, so a bare 400 dead-ends it. Every other path keeps
  `Plug.Parsers`' default behavior (the `ParseError` is re-raised unchanged).
  """
  @behaviour Plug
  import Plug.Conn

  @rpc_path "/api/mcp/rpc"

  @impl Plug
  def init(opts), do: Plug.Parsers.init(opts)

  @impl Plug
  def call(conn, opts) do
    Plug.Parsers.call(conn, opts)
  rescue
    error in Plug.Parsers.ParseError ->
      if conn.request_path == @rpc_path do
        body =
          Phoenix.json_library().encode!(%{
            "jsonrpc" => "2.0",
            "id" => nil,
            "error" => %{"code" => -32_700, "message" => "Parse error"}
          })

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, body)
        |> halt()
      else
        reraise error, __STACKTRACE__
      end
  end
end
