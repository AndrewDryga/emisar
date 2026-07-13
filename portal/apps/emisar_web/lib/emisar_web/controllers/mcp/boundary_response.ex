defmodule EmisarWeb.MCP.BoundaryResponse do
  @moduledoc """
  Shapes JSON-RPC errors raised before MCP method dispatch.

  A parsed request's string or numeric id is safe to echo. A valid notification
  has no id and must receive no response body, even when the HTTP status is an
  error. Callers handling malformed or oversized input opt out of inspecting the
  body because no request id can be trusted at that point.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @type option :: {:inspect_body, boolean()}

  @spec send_error(Plug.Conn.t(), Plug.Conn.status(), integer(), String.t(), [option()]) ::
          Plug.Conn.t()
  def send_error(conn, status, code, message, opts \\ []) do
    inspect_body? = Keyword.get(opts, :inspect_body, true)

    conn = put_status(conn, status)

    if inspect_body? and notification?(conn.body_params) do
      conn
      |> send_resp(status, "")
      |> halt()
    else
      conn
      |> json(%{
        jsonrpc: "2.0",
        id: request_id(conn.body_params, inspect_body?),
        error: %{code: code, message: message}
      })
      |> halt()
    end
  end

  @doc false
  def rate_limited(conn, retry_after) do
    send_error(
      conn,
      :too_many_requests,
      -32_000,
      "Too many requests. Retry in #{retry_after}s."
    )
  end

  defp notification?(%{"jsonrpc" => "2.0", "method" => method} = request)
       when is_binary(method),
       do: not Map.has_key?(request, "id")

  defp notification?(_request), do: false

  defp request_id(%{"jsonrpc" => "2.0", "method" => method, "id" => id}, true)
       when is_binary(method) and (is_binary(id) or is_number(id)),
       do: id

  defp request_id(_request, _inspect_body?), do: nil
end
