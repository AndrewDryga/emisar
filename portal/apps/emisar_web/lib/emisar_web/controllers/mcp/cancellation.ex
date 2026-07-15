defmodule EmisarWeb.MCP.Cancellation do
  @moduledoc """
  Request-scoped MCP cancellation over the existing distributed PubSub.

  A cancellation target is bound to the authenticated account and request API
  key plus the bridge's unguessable request-generation token. A rotation
  successor may also target its immediate predecessor so a peer-promoted bridge
  can cancel work admitted before rotation. Stateless native HTTP requests carry
  no private generation token and are not cross-request cancellable.
  """

  import Plug.Conn, only: [get_req_header: 2, put_private: 3]
  alias Emisar.{Crypto, PubSub}
  alias EmisarWeb.MCP.CancellationRegistry

  @request_token_header "x-emisar-mcp-request-token"
  @cancel_token_header "x-emisar-mcp-cancel-token"
  @topic_private :emisar_mcp_cancellation_topic
  @max_token_bytes 512

  @doc "Run a request while subscribed to its cancellation topic."
  @spec track(Plug.Conn.t(), String.t(), (Plug.Conn.t() -> term())) ::
          term() | :cancelled
  def track(conn, method, fun) when is_function(fun, 1) do
    case request_topic(conn, method) do
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
  @spec cancel(Plug.Conn.t()) :: :ok
  def cancel(conn) do
    conn
    |> cancellation_topics()
    |> Enum.each(fn topic ->
      :ok = CancellationRegistry.record(topic)
      :ok = PubSub.broadcast(topic, {:mcp_request_cancelled, topic})
    end)

    :ok
  end

  defp request_topic(_conn, "initialize"), do: nil

  defp request_topic(conn, _method) do
    token = bounded_header(conn, @request_token_header)

    case conn.assigns[:api_key] do
      %{id: api_key_id} -> scoped_topic(conn, api_key_id, token)
      _ -> nil
    end
  end

  @doc "The exact topic attached to the currently tracked request, if any."
  @spec topic(Plug.Conn.t()) :: String.t() | nil
  def topic(conn), do: Map.get(conn.private, @topic_private)

  defp cancellation_topics(conn) do
    token = bounded_header(conn, @cancel_token_header)

    case conn.assigns[:api_key] do
      %{id: api_key_id, replaces_id: replaces_id} ->
        [api_key_id, replaces_id]
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.map(&scoped_topic(conn, &1, token))
        |> Enum.reject(&is_nil/1)

      %{id: api_key_id} ->
        case scoped_topic(conn, api_key_id, token) do
          nil -> []
          topic -> [topic]
        end

      _ ->
        []
    end
  end

  defp scoped_topic(_conn, _api_key_id, nil), do: nil

  defp scoped_topic(
         %{assigns: %{current_subject: %{account: %{id: account_id}}}},
         api_key_id,
         token
       ) do
    digest =
      [to_string(account_id), to_string(api_key_id), token]
      |> Enum.join(<<0>>)
      |> Crypto.hash()
      |> Base.url_encode64(padding: false)

    "account:#{account_id}:mcp-request:#{digest}"
  end

  defp scoped_topic(_conn, _api_key_id, _token), do: nil

  defp bounded_header(conn, name) do
    case get_req_header(conn, name) do
      [value]
      when is_binary(value) and value != "" and byte_size(value) <= @max_token_bytes ->
        "t:" <> value

      _ ->
        nil
    end
  end

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
