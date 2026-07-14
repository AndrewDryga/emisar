defmodule EmisarWeb.MCP.CatalogCursor do
  @moduledoc """
  Issues short-lived opaque cursors for MCP catalog reads.

  A cursor is bound to its tool, normalized filters, and authorization scope so
  callers cannot reuse it to cross either a query or visibility boundary.
  """

  @salt "mcp-catalog-cursor-v1"
  @max_age_seconds 900
  @max_cursor_bytes 4_096

  @doc "Signs the last emitted sort key for a normalized catalog query."
  @spec encode(String.t(), String.t(), map(), String.t()) :: String.t()
  def encode(tool, scope, filters, last_key) do
    Phoenix.Token.sign(
      EmisarWeb.Endpoint,
      @salt,
      %{"tool" => tool, "scope" => scope, "filters" => filters, "last_key" => last_key}
    )
  end

  @doc "Verifies a cursor and returns its last emitted sort key."
  @spec decode(term(), String.t(), String.t(), map()) ::
          {:ok, nil | String.t()} | {:error, :invalid_cursor}
  def decode(nil, _tool, _scope, _filters), do: {:ok, nil}

  def decode(cursor, tool, scope, filters)
      when is_binary(cursor) and byte_size(cursor) <= @max_cursor_bytes do
    if canonical_token?(cursor) do
      case Phoenix.Token.verify(EmisarWeb.Endpoint, @salt, cursor, max_age: @max_age_seconds) do
        {:ok,
         %{"tool" => ^tool, "scope" => ^scope, "filters" => ^filters, "last_key" => last_key}}
        when is_binary(last_key) ->
          {:ok, last_key}

        _other ->
          {:error, :invalid_cursor}
      end
    else
      {:error, :invalid_cursor}
    end
  end

  def decode(_cursor, _tool, _scope, _filters), do: {:error, :invalid_cursor}

  # Plug.Crypto verifies decoded signature bytes, so alternate Base64URL
  # spellings that differ only in unused padding bits can otherwise verify as
  # the same token. Require the exact unpadded canonical spelling before HMAC
  # verification so opaque cursor identity is byte-stable.
  defp canonical_token?(token) do
    case :binary.split(token, ".", [:global]) do
      [protected, payload, signature] ->
        Enum.all?([protected, payload, signature], &canonical_base64url?/1)

      _other ->
        false
    end
  end

  defp canonical_base64url?(segment) do
    case Base.url_decode64(segment, padding: false) do
      {:ok, decoded} -> Base.url_encode64(decoded, padding: false) == segment
      :error -> false
    end
  end
end
