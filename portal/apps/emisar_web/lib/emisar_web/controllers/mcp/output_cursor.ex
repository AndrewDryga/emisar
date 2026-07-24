defmodule EmisarWeb.MCP.OutputCursor do
  @moduledoc """
  Opaque, scope-bound cursor for the `wait_for_run` output tail.

  Wraps `CatalogCursor` with the fixed `wait_for_run` tool and the run's id as
  the only filter, so a cursor is bound to one run AND one credential lineage:
  it cannot be replayed against another run or another key. The model never
  constructs it — it only echoes the `next` continuation it was handed — and a
  forged, expired, or cross-bound value fails loud as `:invalid_cursor` rather
  than silently re-reading or skipping output.

  A cursor is a `{seq, offset}` position: output has been delivered up to event
  `seq`, `offset` bytes in. `offset` is `0` at an event boundary and non-zero
  only when a large event was fragmented across frames. `{0, 0}` is the
  start-of-output seed.
  """

  alias EmisarWeb.MCP.CatalogCursor

  @tool "wait_for_run"

  @doc "Signs a cursor at `{seq, offset}` for `run_id` within `scope`."
  @spec encode(String.t(), String.t(), non_neg_integer(), non_neg_integer()) :: String.t()
  def encode(scope, run_id, seq, offset)
      when is_integer(seq) and seq >= 0 and is_integer(offset) and offset >= 0,
      do: CatalogCursor.encode(@tool, scope, %{"run_id" => run_id}, "#{seq}:#{offset}")

  @doc """
  Verifies a cursor and returns its `{seq, offset}`, or `:invalid_cursor` when it
  is forged, expired, or bound to another run or credential lineage.
  """
  @spec decode(term(), String.t(), String.t()) ::
          {:ok, {non_neg_integer(), non_neg_integer()}} | {:error, :invalid_cursor}
  def decode(cursor, scope, run_id) do
    with {:ok, last_key} when is_binary(last_key) <-
           CatalogCursor.decode(cursor, @tool, scope, %{"run_id" => run_id}),
         [seq_str, offset_str] <- String.split(last_key, ":", parts: 2),
         {seq, ""} when seq >= 0 <- Integer.parse(seq_str),
         {offset, ""} when offset >= 0 <- Integer.parse(offset_str) do
      {:ok, {seq, offset}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end
end
