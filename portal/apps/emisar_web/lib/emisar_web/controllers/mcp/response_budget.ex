defmodule EmisarWeb.MCP.ResponseBudget do
  @moduledoc """
  Owns the final encoded-size contract for fixed MCP tool responses.

  Fixed results intentionally mirror their payload in `structuredContent` and
  in a JSON text block for clients that do not consume structured content. Size
  checks therefore measure that complete compatibility shape inside its
  JSON-RPC envelope, including escaping, rather than estimating decoded fields.
  """

  @max_frame_bytes 512 * 1_024
  @max_request_id_bytes 4_096

  @doc "Builds the one fixed MCP result representation used on the wire."
  def fixed_result(payload, is_error) when is_map(payload) and is_boolean(is_error) do
    %{
      content: [%{type: "text", text: Jason.encode!(payload)}],
      structuredContent: payload,
      isError: is_error
    }
  end

  @doc "Returns whether a fixed payload fits one final frame for any accepted request id."
  def fits_payload?(payload, is_error \\ false) do
    frame = %{
      jsonrpc: "2.0",
      # NUL has the largest JSON escape among one-byte input characters, so
      # this reserves the true worst case for any accepted string request ID.
      id: String.duplicate("\0", @max_request_id_bytes),
      result: fixed_result(payload, is_error)
    }

    encoded_size(frame) <= @max_frame_bytes
  end

  @doc "Encodes a final frame only when it satisfies the bridge transport ceiling."
  def encode_frame(frame) when is_map(frame) do
    encoded = Jason.encode_to_iodata!(frame)

    if IO.iodata_length(encoded) <= @max_frame_bytes,
      do: {:ok, IO.iodata_to_binary(encoded)},
      else: {:error, :response_too_large}
  end

  @doc "Accepts only IDs whose echoed representation leaves bounded envelope headroom."
  def valid_request_id?(id) when is_binary(id), do: byte_size(id) <= @max_request_id_bytes

  def valid_request_id?(id) when is_integer(id),
    do: byte_size(Integer.to_string(id)) <= @max_request_id_bytes

  def valid_request_id?(_id), do: false

  @doc false
  def max_frame_bytes, do: @max_frame_bytes

  @doc false
  def max_request_id_bytes, do: @max_request_id_bytes

  defp encoded_size(value), do: value |> Jason.encode_to_iodata!() |> IO.iodata_length()
end
