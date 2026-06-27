defmodule Emisar.Maps do
  @moduledoc """
  Small, dependency-free map helpers shared across contexts.
  """

  @doc """
  Puts `key => value` into `map` only when `value` is present, returning `map`
  unchanged otherwise. "Present" is non-nil by default; pass `blank: [...]` to
  treat additional values (e.g. `""`) as absent too.
  """
  def put_present(map, key, value, opts \\ []) do
    if value in Keyword.get(opts, :blank, [nil]) do
      map
    else
      Map.put(map, key, value)
    end
  end
end
