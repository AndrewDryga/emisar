defmodule Emisar.EncodedText do
  @moduledoc """
  One place to measure and cut text in the unit a JSON frame actually spends.

  A ceiling counted in graphemes or in decoded bytes bounds nothing on the wire:
  one emoji is four bytes and one combining cluster is an unbounded number of
  them, while a backslash or quote is one decoded byte that JSON escapes to two
  in structured content and to four again inside a mirrored JSON text block. The
  MCP page frame is budgeted in bytes and carries its payload twice, so every
  free-text field riding it is bounded HERE, in encoded bytes.

  Two projections spend it — the review receipt's justification chain
  (`Emisar.Approvals`) and its command line (`Emisar.Runs`) — and they share
  these primitives so the two bounds cannot drift apart.

  Encoded bytes also hold a JSON Schema `maxLength`, which counts code points:
  no code point encodes shorter than one byte. Cuts land on a code point
  boundary, so the result is always valid UTF-8.

  See `.agent/kb/rules/elixir-byte-budgets-need-byte-bounds.md`.
  """

  @doc """
  The bytes `text` costs inside a JSON document under Jason's default escaping,
  the mode the MCP frame is encoded with: its escaped form, without the
  enclosing quotes.
  """
  @spec size(String.t()) :: non_neg_integer()
  def size(text) when is_binary(text), do: byte_size(Jason.encode!(text)) - 2

  @doc """
  The longest prefix of `text` whose encoded form is within `limit` bytes and
  ends on a code point boundary. JSON escapes one code point at a time, so the
  encoded sizes add up; a code point is never split, so the cut is valid UTF-8.
  """
  @spec prefix_within(String.t(), pos_integer()) :: String.t()
  def prefix_within(text, limit) when is_binary(text) and is_integer(limit) and limit > 0 do
    text
    |> String.codepoints()
    |> Enum.reduce_while({[], 0}, fn codepoint, {kept, size} ->
      case size + size(codepoint) do
        size when size <= limit -> {:cont, {[codepoint | kept], size}}
        _over -> {:halt, {kept, size}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  @doc """
  `text` bounded at `limit` encoded bytes as `{text, cut?}`, so a caller can
  publish an honest truncation flag beside it. Text that fits is returned
  untouched.
  """
  @spec bound(String.t(), pos_integer()) :: {String.t(), boolean()}
  def bound(text, limit) when is_binary(text) and is_integer(limit) and limit > 0 do
    if size(text) <= limit,
      do: {text, false},
      else: {prefix_within(text, limit), true}
  end
end
