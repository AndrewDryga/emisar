defmodule EmisarWeb.RequestContext do
  @moduledoc """
  Builds an `Emisar.RequestContext` from the inbound HTTP connection or
  the LiveView socket — the web boundary's single place for pulling the
  client IP, user agent, request id, and MCP session id off the wire.

  The resulting struct is carried on `%Auth.Subject{}.context` for an
  authenticated caller (so every audit row the caller produces inherits
  the request metadata) or passed explicitly on a pre-auth path. Nothing
  below the boundary ever sees a `Plug.Conn`.

  Behind a proxy, `x-forwarded-for` is trusted for the client IP; without
  one we fall back to the socket peer. (`Plug.RemoteIp` is not in the
  pipeline, so a spoofable header is the documented trade-off — audit IPs
  are advisory, not an access-control input.)
  """
  import Plug.Conn, only: [get_req_header: 2, get_resp_header: 2]
  alias Emisar.RequestContext

  @doc "Request context for an HTTP request (`%Plug.Conn{}`)."
  def from_conn(conn) do
    RequestContext.new(%{
      ip_address: normalize_ip(forwarded_for(conn) || peer_ip(conn)),
      user_agent: List.first(get_req_header(conn, "user-agent")),
      request_id: List.first(get_resp_header(conn, "x-request-id")),
      mcp_session_id: List.first(get_req_header(conn, "mcp-session-id"))
    })
  end

  @doc """
  Request context for a LiveView socket, from its connect info. Carries
  IP + user agent only — request id and MCP session are HTTP-request
  concerns the socket doesn't have. Like `from_conn/1`, the client IP comes
  from `x-forwarded-for` (Fly's LB is the socket's only peer, so without it
  the audit/geo IP would be the load balancer). Requires `:peer_data`,
  `:user_agent`, and `:x_headers` in the endpoint's `socket "/live"`
  `connect_info`.
  """
  def from_socket(socket) do
    peer_ip = format_peer_ip(Phoenix.LiveView.get_connect_info(socket, :peer_data))

    RequestContext.new(%{
      ip_address: normalize_ip(forwarded_for_socket(socket) || peer_ip),
      user_agent: Phoenix.LiveView.get_connect_info(socket, :user_agent)
    })
  end

  defp forwarded_for(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [val | _] -> first_forwarded(val)
      [] -> nil
    end
  end

  defp forwarded_for_socket(socket) do
    case Phoenix.LiveView.get_connect_info(socket, :x_headers) do
      headers when is_list(headers) ->
        case List.keyfind(headers, "x-forwarded-for", 0) do
          {_name, val} -> first_forwarded(val)
          nil -> nil
        end

      _ ->
        nil
    end
  end

  defp first_forwarded(val), do: val |> String.split(",") |> List.first() |> String.trim()

  defp peer_ip(%{remote_ip: ip}) when is_tuple(ip),
    do: ip |> :inet_parse.ntoa() |> to_string()

  defp peer_ip(_), do: nil

  defp format_peer_ip(%{address: ip}) when is_tuple(ip),
    do: ip |> :inet_parse.ntoa() |> to_string()

  defp format_peer_ip(_), do: nil

  # IPv6-listener sockets surface IPv4 clients as `::ffff:N.N.N.N`
  # (the IPv4-mapped IPv6 encoding). Operators don't care about the
  # wrapper — strip it so audit columns show `1.2.3.4`, not the
  # awkward 20-character form that overflows the column.
  defp normalize_ip(nil), do: nil
  defp normalize_ip("::ffff:" <> ip4), do: ip4
  defp normalize_ip(ip), do: ip
end
