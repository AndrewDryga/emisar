defmodule EmisarWeb.MCP.Transport do
  @moduledoc """
  Pure Streamable-HTTP transport-conformance predicates for every MCP revision
  the stateless `/api/mcp/rpc` endpoint serves — the modern 2026-07-28
  per-request-`_meta` revision and the legacy `initialize`-negotiated
  2025-11-25 / 2025-06-18 revisions. The controller wires each into a plug or
  request check; keeping the decision pure makes every rule unit-testable in
  isolation.

  emisar is a JSON-only, **stateless** MCP server: it opens no SSE stream and
  issues no MCP session id, so a GET/DELETE to the endpoint is answered `405`.
  On POST it accepts only a JSON body, requires the client to accept
  `application/json` back, validates the `MCP-Protocol-Version` header when
  present on a post-initialize request, and rejects a cross-origin browser
  `Origin` (the spec's DNS-rebinding Security Warning). A request declaring
  the modern revision in `_meta` additionally has its `Mcp-Method`/`Mcp-Name`
  routing headers validated against the body.
  """

  @doc """
  True when the request's `Origin` is allowed: absent (server-to-server MCP
  clients, the stdio bridge, curl — none send a browser `Origin`) or exactly the
  server's own origin. A present cross-origin value is rejected, and so is a
  duplicated header: different intermediaries pick different copies, so an
  ambiguous singleton fails closed instead of trusting whichever came first.
  """
  def allowed_origin?([], _allowed), do: true
  def allowed_origin?([origin], allowed), do: origin == allowed
  def allowed_origin?(_values, _allowed), do: false

  @doc """
  True when the POST body is JSON. The `Content-Type` may carry parameters
  (`application/json; charset=utf-8`). An absent content type is tolerated — the
  parser already turned any non-JSON body into an empty frame the handler
  rejects as an invalid request.
  """
  def json_content_type?([]), do: true
  def json_content_type?([content_type]), do: media_type(content_type) == "application/json"
  def json_content_type?(_values), do: false

  @doc """
  True when the client accepts a JSON response — absent `Accept` (treated as
  `*/*`), `*/*`, `application/*`, or an explicit `application/json`. A client
  that accepts only `text/event-stream` (an SSE-only request) can't be served by
  this JSON-only endpoint. `Accept` is a legitimately repeatable header, so
  every field value counts — HTTP treats repeated lines as one comma-joined
  list, unlike the singleton headers above.
  """
  def accepts_json?([]), do: true
  def accepts_json?(accepts), do: Enum.any?(accepts, &accepts_json_value?/1)

  @doc """
  True when the `MCP-Protocol-Version` header is acceptable on a post-initialize
  request: absent (the spec assumes the backwards-compatible default) or one of
  the server's `supported` versions. The `initialize` request negotiates the
  version in its JSON body, so its header is not validated here.
  """
  def acceptable_protocol_version?([], _supported), do: true
  def acceptable_protocol_version?([version], supported), do: version in supported
  def acceptable_protocol_version?(_values, _supported), do: false

  @doc """
  The protocol version a 2026-07-28 request declares per-request in its
  `params._meta` (`io.modelcontextprotocol/protocolVersion`), or nil for a
  legacy request that negotiated at `initialize` instead.
  """
  def meta_protocol_version(%{"_meta" => %{"io.modelcontextprotocol/protocolVersion" => version}})
      when is_binary(version),
      do: version

  def meta_protocol_version(_params), do: nil

  @doc """
  True when the `Mcp-Name` header names the called tool — required on a
  2026-07-28 `tools/call`. A name outside the header-safe ASCII set arrives
  wrapped in the spec's `=?base64?…?=` sentinel and is decoded before the
  comparison; an absent or undecodable header never matches.
  """
  def mcp_name_matches?([value], name) when is_binary(name),
    do: decode_header_value(value) == name

  def mcp_name_matches?(_values, _name), do: false

  defp decode_header_value("=?base64?" <> rest) do
    with true <- String.ends_with?(rest, "?="),
         encoded = binary_part(rest, 0, byte_size(rest) - 2),
         {:ok, decoded} <- Base.decode64(encoded) do
      decoded
    else
      _ -> nil
    end
  end

  defp decode_header_value(value), do: value

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
