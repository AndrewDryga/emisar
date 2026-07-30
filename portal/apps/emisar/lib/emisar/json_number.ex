defmodule Emisar.JSONNumber do
  @moduledoc """
  An exact JSON number token retained when normalized floats would lose request
  identity or validation precision.
  """

  defstruct [:raw]

  @type t :: %__MODULE__{raw: binary()}
end

defimpl Jason.Encoder, for: Emisar.JSONNumber do
  @number ~r/\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z/

  def encode(%Emisar.JSONNumber{raw: raw}, _opts) do
    if Regex.match?(@number, raw), do: raw, else: raise(ArgumentError, "invalid JSON number")
  end
end
