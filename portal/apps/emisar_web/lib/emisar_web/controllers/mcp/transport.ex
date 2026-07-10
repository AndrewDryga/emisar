defmodule EmisarWeb.MCP.Transport do
  @moduledoc """
  Pure Streamable-HTTP (MCP 2025-06-18) transport-conformance predicates for the
  stateless `/api/mcp/rpc` endpoint. The controller wires each into a plug;
  keeping the decision pure makes every rule unit-testable in isolation.

  emisar is a JSON-only, **stateless** MCP server: it opens no SSE stream and
  issues no durable session, so a GET/DELETE to the endpoint is answered `405`.
  On POST it accepts only a JSON body, requires the client to accept
  `application/json` back, validates the `MCP-Protocol-Version` header when
  present on a post-initialize request, and rejects a cross-origin browser
  `Origin` (the spec's DNS-rebinding Security Warning).
  """

  @doc """
  True when the request's `Origin` is allowed: absent (server-to-server MCP
  clients, the stdio bridge, curl — none send a browser `Origin`) or exactly the
  server's own origin. A present cross-origin value is rejected.
  """
  def allowed_origin?([], _allowed), do: true
  def allowed_origin?([origin | _], allowed), do: origin == allowed

  @doc """
  True when the POST body is JSON. The `Content-Type` may carry parameters
  (`application/json; charset=utf-8`). An absent content type is tolerated — the
  parser already turned any non-JSON body into an empty frame the handler
  rejects as an invalid request.
  """
  def json_content_type?([]), do: true
  def json_content_type?([content_type | _]), do: media_type(content_type) == "application/json"

  @doc """
  True when the client accepts a JSON response — absent `Accept` (treated as
  `*/*`), `*/*`, `application/*`, or an explicit `application/json`. A client
  that accepts only `text/event-stream` (an SSE-only request) can't be served by
  this JSON-only endpoint.
  """
  def accepts_json?([]), do: true
  def accepts_json?([accept | _]), do: accepts_json_value?(accept)

  @doc """
  True when the `MCP-Protocol-Version` header is acceptable on a post-initialize
  request: absent (the spec assumes the backwards-compatible default) or one of
  the server's `supported` versions. The `initialize` request negotiates the
  version in its JSON body, so its header is not validated here.
  """
  def acceptable_protocol_version?([], _supported), do: true
  def acceptable_protocol_version?([version | _], supported), do: version in supported

  defp accepts_json_value?(accept) do
    accept
    |> String.split(",")
    |> Enum.map(&media_type/1)
    |> Enum.any?(&(&1 in ["application/json", "application/*", "*/*"]))
  end

  # Strip parameters (`; charset=…`) and normalize to a lowercased, trimmed
  # media type.
  defp media_type(value) do
    value
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
    |> String.downcase()
  end
end
