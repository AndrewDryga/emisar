defmodule EmisarWeb.Plugs.AuditContext do
  @moduledoc """
  Stashes IP, user agent, and request id from the current connection
  into the process dictionary so any downstream `Emisar.Audit.log/3`
  call picks them up without each business context having to be
  refactored to thread a `Plug.Conn` through.

  Wired into the `:browser` and `:api` pipelines in the router. The
  matching LiveView entry point is `EmisarWeb.UserAuth.on_mount(:audit_meta, …)`.

  Behind a proxy without `Plug.RemoteIp` configured, this records the
  proxy IP rather than the originating client IP.
  """

  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    Emisar.Audit.put_request_metadata(%{
      ip_address: format_ip(conn.remote_ip),
      user_agent: header(conn, "user-agent"),
      request_id: Logger.metadata()[:request_id],
      mcp_session_id: header(conn, "mcp-session-id")
    })

    conn
  end

  defp format_ip(ip) when is_tuple(ip), do: ip |> :inet_parse.ntoa() |> to_string()
  defp format_ip(_), do: nil

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [v | _] -> v
      [] -> nil
    end
  end
end
