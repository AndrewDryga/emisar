defmodule EmisarWeb.MCP.CatalogCursor do
  @moduledoc """
  Issues short-lived opaque cursors for MCP catalog reads.

  A cursor is bound to its tool, normalized filters, and authorization scope so
  callers cannot reuse it to cross either a query or visibility boundary. Page
  size is deliberately not one of those filters: `limit` is a per-call ceiling
  on the next page, not part of the query, so changing it while paging must
  never invalidate a continuation.
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
    case Phoenix.Token.verify(EmisarWeb.Endpoint, @salt, cursor, max_age: @max_age_seconds) do
      {:ok, %{"tool" => ^tool, "scope" => ^scope, "filters" => ^filters, "last_key" => last_key}}
      when is_binary(last_key) ->
        {:ok, last_key}

      _other ->
        {:error, :invalid_cursor}
    end
  end

  def decode(_cursor, _tool, _scope, _filters), do: {:error, :invalid_cursor}
end
