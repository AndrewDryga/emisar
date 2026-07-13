defmodule EmisarWeb.MCP.Cancellation do
  @moduledoc """
  Request-scoped MCP cancellation over the existing distributed PubSub.

  A cancellation target is bound to the authenticated account and API key, the
  MCP session, and either the bridge's generation token or the request's typed
  JSON-RPC id. This prevents one key or session from cancelling another and
  prevents a late bridge notification from cancelling a reused id.
  """

  import Plug.Conn, only: [get_req_header: 2, put_private: 3]
  alias Emisar.{Crypto, PubSub}
  alias EmisarWeb.MCP.CancellationRegistry
  alias EmisarWeb.RequestContext

  @request_token_header "x-emisar-mcp-request-token"
  @cancel_token_header "x-emisar-mcp-cancel-token"
  @topic_private :emisar_mcp_cancellation_topic
  @max_token_bytes 512
  @max_request_id_bytes 1_024

  @doc "Run a request while subscribed to its cancellation topic."
  @spec track(Plug.Conn.t(), String.t(), term(), (Plug.Conn.t() -> term())) ::
          term() | :cancelled
  def track(conn, method, request_id, fun) when is_function(fun, 1) do
    case request_topic(conn, method, request_id) do
      nil ->
        fun.(conn)

      topic ->
        :ok = PubSub.subscribe(topic)
        tracked_conn = put_private(conn, @topic_private, topic)

        try do
          if cancelled?(topic) do
            :cancelled
          else
            result = fun.(tracked_conn)
            if cancelled?(topic), do: :cancelled, else: result
          end
        after
          :ok = PubSub.unsubscribe(topic)
          :ok = CancellationRegistry.complete(topic)
        end
    end
  end

  @doc "Broadcast a best-effort cancellation for a notification's target."
  @spec cancel(Plug.Conn.t(), map()) :: :ok
  def cancel(conn, params) do
    case cancellation_topic(conn, params) do
      nil ->
        :ok

      topic ->
        :ok = CancellationRegistry.record(topic)
        PubSub.broadcast(topic, {:mcp_request_cancelled, topic})
    end
  end

  @doc "The exact topic attached to the currently tracked request, if any."
  @spec topic(Plug.Conn.t()) :: String.t() | nil
  def topic(conn), do: Map.get(conn.private, @topic_private)

  defp request_topic(_conn, "initialize", _request_id), do: nil

  defp request_topic(conn, _method, request_id) do
    token = bounded_header(conn, @request_token_header) || typed_request_id(request_id)
    scoped_topic(conn, token)
  end

  defp cancellation_topic(conn, params) do
    token = bounded_header(conn, @cancel_token_header) || typed_request_id(params["requestId"])
    scoped_topic(conn, token)
  end

  defp scoped_topic(_conn, nil), do: nil

  defp scoped_topic(conn, token) do
    with %{id: api_key_id} <- conn.assigns[:api_key],
         %{account: %{id: account_id}} <- conn.assigns[:current_subject],
         session when is_binary(session) <- RequestContext.mcp_session_id(conn) do
      digest =
        [to_string(account_id), to_string(api_key_id), session, token]
        |> Enum.join(<<0>>)
        |> Crypto.hash()
        |> Base.url_encode64(padding: false)

      "account:#{account_id}:mcp-request:#{digest}"
    else
      _ -> nil
    end
  end

  defp bounded_header(conn, name) do
    case get_req_header(conn, name) do
      [value]
      when is_binary(value) and value != "" and byte_size(value) <= @max_token_bytes ->
        "t:" <> value

      _ ->
        nil
    end
  end

  defp typed_request_id(id)
       when is_binary(id) and byte_size(id) <= @max_request_id_bytes,
       do: "s:" <> id

  defp typed_request_id(id) when is_integer(id) do
    encoded = Integer.to_string(id)
    if byte_size(encoded) <= @max_request_id_bytes, do: "n:" <> encoded
  end

  defp typed_request_id(_id), do: nil

  defp cancelled?(topic) do
    CancellationRegistry.cancelled?(topic) || cancellation_message?(topic)
  end

  defp cancellation_message?(topic) do
    receive do
      {:mcp_request_cancelled, ^topic} -> true
    after
      0 -> false
    end
  end
end
