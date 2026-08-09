defmodule Emisar.Runbooks.DefinitionDiff do
  @moduledoc """
  Line diff between two runbook definitions.

  The compared text is exactly what `Emisar.CanonicalJSON` hashes into a
  definition's `definition_sha256`, so what this shows is what changed the
  definition's identity — there is no second serialization to drift from it.

  A JSON line diff cannot tell a MOVE from a delete plus an insert, so
  reordering stages reads as a large change. That is the accepted cost of not
  building a structural differ: the shape here is the review surface, and a
  semantic differ would replace this module without moving where it renders.
  """

  alias Emisar.CanonicalJSON

  # Unified-diff convention: enough neighbouring lines to place a change inside
  # its stage or step without rendering an unchanged document around it.
  @context_lines 3

  # Bounded because a definition can be edited into a diff far larger than any
  # review surface should render. Overflow is reported, never silently dropped.
  @max_lines 400

  defstruct hunks: [], truncated?: false

  @type op :: :eq | :del | :ins
  @type line :: {op(), String.t()}
  @type t :: %__MODULE__{hunks: [[line()]], truncated?: boolean()}

  @doc """
  Builds the diff carrying `previous` forward to `current`.

  Returns a `%DefinitionDiff{}` whose `hunks` are the changed runs plus
  #{@context_lines} lines of context either side. Identical definitions produce
  no hunks, which is a real outcome: a version whose title alone changed.
  """
  @spec build(map(), map()) :: t()
  def build(previous, current) when is_map(previous) and is_map(current) do
    previous
    |> lines()
    |> List.myers_difference(lines(current))
    |> flatten()
    |> hunks()
    |> truncate()
  end

  defp lines(definition), do: definition |> CanonicalJSON.encode_pretty!() |> String.split("\n")

  defp flatten(difference) do
    Enum.flat_map(difference, fn {op, lines} -> Enum.map(lines, &{op, &1}) end)
  end

  defp hunks(lines) do
    kept = kept_indexes(lines)

    if MapSet.size(kept) == 0 do
      []
    else
      lines
      |> Enum.with_index()
      |> Enum.filter(fn {_line, index} -> MapSet.member?(kept, index) end)
      |> chunk_adjacent()
    end
  end

  defp kept_indexes(lines) do
    lines
    |> Enum.with_index()
    |> Enum.reduce(MapSet.new(), fn
      {{:eq, _line}, _index}, kept ->
        kept

      {{_op, _line}, index}, kept ->
        window = max(index - @context_lines, 0)..(index + @context_lines)
        Enum.reduce(window, kept, &MapSet.put(&2, &1))
    end)
  end

  defp chunk_adjacent(indexed) do
    indexed
    |> Enum.reduce([], fn
      {line, index}, [{previous, hunk} | rest] when index == previous + 1 ->
        [{index, [line | hunk]} | rest]

      {line, index}, hunks ->
        [{index, [line]} | hunks]
    end)
    |> Enum.reverse()
    |> Enum.map(fn {_index, hunk} -> Enum.reverse(hunk) end)
  end

  defp truncate(hunks) do
    total = hunks |> Enum.map(&length/1) |> Enum.sum()

    if total <= @max_lines do
      %__MODULE__{hunks: hunks, truncated?: false}
    else
      %__MODULE__{hunks: take_lines(hunks, @max_lines), truncated?: true}
    end
  end

  defp take_lines(_hunks, remaining) when remaining <= 0, do: []
  defp take_lines([], _remaining), do: []

  defp take_lines([hunk | rest], remaining) do
    taken = Enum.take(hunk, remaining)
    [taken | take_lines(rest, remaining - length(taken))]
  end
end
